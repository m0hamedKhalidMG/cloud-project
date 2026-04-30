# CISC 886 – Cloud Computing Project
## End-to-End Cloud Chat Assistant on AWS

**Queen's netIDs:** `25kp55-25hfnv-25vft4`
**Region:** `us-east-1`
**Model:** Llama 3.2 3B Instruct (fine-tuned with QLoRA on Alpaca)

---

## Repository Structure

```
.
├── terraform/
│   └── main.tf                  # VPC, subnet, IGW, route table, SG, EC2
├── spark/
│   └── preprocess.py            # PySpark preprocessing pipeline (Section 4)
├── notebooks/
│   └── finetune.ipynb           # Fine-tuning notebook (Section 5)
├── scripts/
│   └── setup_ec2.sh             # EC2 setup: Ollama + OpenWebUI (Sections 6 & 7)
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| AWS CLI | ≥ 2.x | `pip install awscli` |
| Terraform | ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| Python | ≥ 3.10 | https://python.org |
| Docker | ≥ 24 | https://docs.docker.com/get-docker/ |
| Ollama | latest | https://ollama.com/download |

**AWS accounts/permissions required:**
- IAM user with `AmazonEC2FullAccess`, `AmazonEMRFullAccessPolicy_v2`,
  `AmazonS3FullAccess`, `AWSGlueConsoleFullAccess`
- Shared Queen's AWS account (contact course TA for credentials)

---

## Step-by-Step Replication

### Phase 1 — Infrastructure (Section 2)

```bash
# 1. Clone this repo
git clone https://github.com/20596365/cloud-project.git
cd cloud-project

# 2. Configure AWS credentials
aws configure   # enter your Access Key ID, Secret, region=us-east-1

# 3. Find your public IP
curl ifconfig.me   # copy this for the my_ip_cidr variable

# 4. Provision the VPC and EC2 instance
cd terraform
terraform init
terraform apply \
    -var="student_id=20596365" \
    -var="my_ip_cidr=$(curl -s ifconfig.me)/32"
# Note the ec2_public_ip and openwebui_url outputs

cd ..
```

### Phase 2 — Data Preprocessing on EMR (Section 4)

```bash
# 1. Create S3 buckets
aws s3 mb s3://20596365-s3-dataset --region us-east-1

# 2. Upload raw dataset and PySpark script
curl -L https://raw.githubusercontent.com/tatsu-lab/stanford_alpaca/main/alpaca_data.json \
    -o alpaca_data.json
aws s3 cp alpaca_data.json s3://20596365-s3-dataset/raw/
aws s3 cp spark/preprocess.py s3://20596365-s3-dataset/scripts/

# 3. Launch EMR cluster and submit Spark job
aws emr create-cluster \
    --name "20596365-emr" \
    --release-label emr-7.0.0 \
    --applications Name=Spark \
    --instance-type m5.xlarge \
    --instance-count 3 \
    --use-default-roles \
    --region us-east-1 \
    --steps Type=Spark,Name="20596365-preprocess",\
ActionOnFailure=CONTINUE,\
Args=[s3://20596365-s3-dataset/scripts/preprocess.py,\
--input,s3://20596365-s3-dataset/raw/alpaca_data.json,\
--output,s3://20596365-s3-dataset/processed/]

# 4. Wait for the step to finish (~10-15 min), then TERMINATE the cluster
#    (required — leaving it running depletes the shared account)
aws emr list-clusters --active   # note the ClusterId
aws emr terminate-clusters --cluster-ids <ClusterId>

# 5. Verify output files in S3
aws s3 ls s3://20596365-s3-dataset/processed/ --recursive
```

### Phase 3 — Fine-Tuning (Section 5)

1. Open `notebooks/finetune.ipynb` in Google Colab
2. Select **Runtime → Change runtime type → T4 GPU**
3. Run all cells in order
4. After the final cell, download `20596365-llama3.2-3b-alpaca-Q4_K_M.gguf`

### Phase 4 — EC2 Deployment (Sections 6 & 7)

```bash
# 1. Upload the GGUF file to EC2
EC2_IP=$(terraform -chdir=terraform output -raw ec2_public_ip)

ssh -i ~/.ssh/id_rsa ubuntu@${EC2_IP} "mkdir -p ~/models"
scp -i ~/.ssh/id_rsa 20596365-llama3.2-3b-alpaca-Q4_K_M.gguf \
    ubuntu@${EC2_IP}:~/models/

# 2. Run the setup script
scp -i ~/.ssh/id_rsa scripts/setup_ec2.sh ubuntu@${EC2_IP}:~/
ssh -i ~/.ssh/id_rsa ubuntu@${EC2_IP} "bash setup_ec2.sh"

# 3. Test the API
curl http://${EC2_IP}:11434/api/generate \
    -d '{"model":"20596365-llama3-alpaca","prompt":"What is cloud computing?","stream":false}'

# 4. Open OpenWebUI in your browser
echo "Visit: http://${EC2_IP}:3000"
```

---

## Cost Summary

| AWS Service | Usage | Approximate Cost |
|---|---|---|
| EC2 `t3.xlarge` | ~4 hours (deployment + demo) | ~$2.10 |
| EMR `m5.xlarge` × 3 nodes | ~30 min | ~$0.22 |
| S3 | < 1 GB storage + transfers | ~$0.03 |
| Data transfer | Minimal | ~$0.05 |
| **Total** | | **~$2.40** |

*Costs are estimates based on on-demand us-east-1 pricing as of April 2026.
Terminate all resources after grading to avoid ongoing charges.*

---

## Teardown

```bash
# Terminate EC2 and VPC resources
cd terraform && terraform destroy \
    -var="student_id=20596365" \
    -var="my_ip_cidr=0.0.0.0/0"

# Delete S3 buckets
aws s3 rb s3://20596365-s3-dataset --force
```
