"""
CISC 886 – Section 4: Data Preprocessing with Apache Spark on EMR
File: spark/preprocess.py

EMR cluster configuration used:
  - Instance type: m5.xlarge (1 master + 2 core nodes)
  - Region: us-east-1
  - EMR release: emr-7.0.0 (Spark 3.5)
  - Resource name: 20596365-emr

Run command (from EMR master or via EMR Steps):
  spark-submit s3://20596365-s3-dataset/scripts/preprocess.py \
      --input  s3://20596365-s3-dataset/raw/alpaca_data.json \
      --output s3://20596365-s3-dataset/processed/

Expected output files in S3:
  s3://20596365-s3-dataset/processed/train/
  s3://20596365-s3-dataset/processed/validation/
  s3://20596365-s3-dataset/processed/test/
  s3://20596365-s3-dataset/processed/eda_stats.json
"""

import argparse
import json
import re
from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from pyspark.sql.types import IntegerType, StringType, StructField, StructType

# ---------------------------------------------------------------------------
# 1. Parse command-line arguments
#    --input  : S3 path to the raw Alpaca JSON file
#    --output : S3 prefix where processed splits will be written
# ---------------------------------------------------------------------------
parser = argparse.ArgumentParser(description="CISC 886 Alpaca Preprocessing")
parser.add_argument("--input",  required=True, help="S3 URI of raw dataset JSON")
parser.add_argument("--output", required=True, help="S3 URI prefix for output")
args = parser.parse_args()

INPUT_PATH  = args.input
OUTPUT_PATH = args.output.rstrip("/")

# ---------------------------------------------------------------------------
# 2. Initialise Spark session
#    The application name helps identify this job in the EMR history server.
# ---------------------------------------------------------------------------
spark = (
    SparkSession.builder
    .appName("20596365-alpaca-preprocess")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")   # reduce console noise

# ---------------------------------------------------------------------------
# 3. Load raw dataset
#    The Alpaca dataset is a JSON array; Spark's json reader handles this with
#    the multiLine option.  Each record has three string fields.
# ---------------------------------------------------------------------------
schema = StructType([
    StructField("instruction", StringType(), nullable=False),
    StructField("input",       StringType(), nullable=True),
    StructField("output",      StringType(), nullable=False),
])

raw_df = (
    spark.read
    .option("multiLine", "true")
    .schema(schema)
    .json(INPUT_PATH)
)

print(f"[INFO] Total records loaded: {raw_df.count()}")

# ---------------------------------------------------------------------------
# 4. Basic cleaning
#    a) Drop rows where instruction or output is null/empty.
#    b) Strip leading/trailing whitespace from all text fields.
#    c) Replace null 'input' with empty string (some samples have no extra
#       context; treating null and "" equivalently simplifies downstream code).
# ---------------------------------------------------------------------------
cleaned_df = (
    raw_df
    .filter(F.col("instruction").isNotNull() & (F.trim(F.col("instruction")) != ""))
    .filter(F.col("output").isNotNull()      & (F.trim(F.col("output"))      != ""))
    .withColumn("instruction", F.trim(F.col("instruction")))
    .withColumn("input",       F.coalesce(F.trim(F.col("input")), F.lit("")))
    .withColumn("output",      F.trim(F.col("output")))
)

print(f"[INFO] Records after cleaning: {cleaned_df.count()}")

# ---------------------------------------------------------------------------
# 5. Feature engineering: token-length approximation
#    A proper BPE tokeniser is not available inside Spark; we use a simple
#    whitespace-split word count as a proxy for token count.  This is
#    sufficient for EDA and for filtering out extremely long samples that
#    would exceed the model's context window (2048 tokens).
#
#    We create three length columns for EDA figures:
#      - instruction_len : word count of the instruction field
#      - input_len       : word count of the input field
#      - output_len      : word count of the output field
# ---------------------------------------------------------------------------
def approx_token_count(text):
    """Rough token count: split on whitespace after collapsing runs of spaces."""
    if text is None or text.strip() == "":
        return 0
    return len(re.split(r"\s+", text.strip()))

approx_token_count_udf = F.udf(approx_token_count, IntegerType())

featured_df = (
    cleaned_df
    .withColumn("instruction_len", approx_token_count_udf(F.col("instruction")))
    .withColumn("input_len",       approx_token_count_udf(F.col("input")))
    .withColumn("output_len",      approx_token_count_udf(F.col("output")))
)

# ---------------------------------------------------------------------------
# 6. Filter outliers
#    Remove samples where the combined prompt + response would likely exceed
#    the model context window.  2048 tokens is the Llama 3.2 3B default.
#    We keep a safety margin and discard anything over 400 output words.
# ---------------------------------------------------------------------------
filtered_df = featured_df.filter(F.col("output_len") <= 400)

print(f"[INFO] Records after outlier filter (output_len <= 400): {filtered_df.count()}")

# ---------------------------------------------------------------------------
# 7. Format for instruction fine-tuning
#    Combine the three fields into a single 'text' column using the Alpaca
#    prompt template.  This is the exact format Unsloth/TRL expects.
#    Samples with a non-empty 'input' use the "with input" variant.
# ---------------------------------------------------------------------------
PROMPT_WITH_INPUT = (
    "Below is an instruction that describes a task, paired with an input that "
    "provides further context. Write a response that appropriately completes the "
    "request.\n\n"
    "### Instruction:\n{instruction}\n\n"
    "### Input:\n{input}\n\n"
    "### Response:\n{output}"
)

PROMPT_NO_INPUT = (
    "Below is an instruction that describes a task. Write a response that "
    "appropriately completes the request.\n\n"
    "### Instruction:\n{instruction}\n\n"
    "### Response:\n{output}"
)

def format_prompt(instruction, inp, output):
    if inp and inp.strip():
        return PROMPT_WITH_INPUT.format(
            instruction=instruction, input=inp, output=output
        )
    return PROMPT_NO_INPUT.format(instruction=instruction, output=output)

format_prompt_udf = F.udf(format_prompt, StringType())

formatted_df = filtered_df.withColumn(
    "text",
    format_prompt_udf(F.col("instruction"), F.col("input"), F.col("output"))
)

# ---------------------------------------------------------------------------
# 8. Compute EDA statistics (on full cleaned dataset before split)
#    These numbers feed the three required EDA figures in the report.
# ---------------------------------------------------------------------------
eda = formatted_df.select(
    "instruction_len", "input_len", "output_len"
).describe().toPandas()

print("[INFO] EDA summary statistics:")
print(eda.to_string())

# Collect histogram buckets for token-length distribution
# (instruction_len buckets)
inst_buckets = (
    formatted_df
    .groupBy(
        (F.floor(F.col("instruction_len") / 10) * 10).alias("bucket")
    )
    .count()
    .orderBy("bucket")
    .toPandas()
)

# Collect input presence (class balance proxy)
input_presence = (
    formatted_df
    .withColumn("has_input", (F.col("input_len") > 0).cast("string"))
    .groupBy("has_input")
    .count()
    .toPandas()
)

# Save EDA stats to S3 as JSON for report reference
eda_stats = {
    "instruction_len_describe": eda.to_dict(),
    "instruction_len_histogram": inst_buckets.to_dict(orient="records"),
    "input_presence": input_presence.to_dict(orient="records"),
}
eda_json = spark.sparkContext.parallelize([json.dumps(eda_stats)])
eda_json.saveAsTextFile(f"{OUTPUT_PATH}/eda_stats")

# ---------------------------------------------------------------------------
# 9. Train / Validation / Test split (80 / 10 / 10)
#    randomSplit uses the same seed (42) every run, guaranteeing identical
#    splits for reproducibility and preventing data leakage between the
#    training statistics and the test set.
# ---------------------------------------------------------------------------
train_df, val_df, test_df = formatted_df.randomSplit([0.8, 0.1, 0.1], seed=42)

print(f"[INFO] Train size:      {train_df.count()}")
print(f"[INFO] Validation size: {val_df.count()}")
print(f"[INFO] Test size:       {test_df.count()}")

# ---------------------------------------------------------------------------
# 10. Write splits to S3
#     Parquet is chosen over CSV because:
#       - It preserves data types (no ambiguous string parsing).
#       - It is column-oriented, so downstream tools can read only the
#         'text' column without loading the whole file.
#       - It is splittable, so future Spark jobs can parallelise reads.
# ---------------------------------------------------------------------------
select_cols = ["instruction", "input", "output", "text",
               "instruction_len", "input_len", "output_len"]

(train_df.select(select_cols)
         .write.mode("overwrite")
         .parquet(f"{OUTPUT_PATH}/train"))

(val_df.select(select_cols)
       .write.mode("overwrite")
       .parquet(f"{OUTPUT_PATH}/validation"))

(test_df.select(select_cols)
        .write.mode("overwrite")
        .parquet(f"{OUTPUT_PATH}/test"))

print(f"[INFO] All splits written to {OUTPUT_PATH}/")

spark.stop()
