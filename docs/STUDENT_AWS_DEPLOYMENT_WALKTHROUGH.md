# AWS Setup, Deploy, Run, and Remove with CodeBuild

**Week 5 command guide | Same hosted release route used by the course API**

Read [Project architecture](PROJECT_ARCHITECTURE.md) first.

This guide uses:

```text
GitHub
  -> AWS CodeBuild
  -> Docker runs inside CodeBuild
  -> image pushed to ECR
  -> ECS service rollout
  -> ALB public API
```

Students do not need Docker Desktop for this route. They need:

- their own AWS account;
- their own GitHub repository containing this project;
- AWS CLI;
- Terraform;
- Git;
- the Python environment and trained model artifacts.

The deployment creates billable AWS resources. Use only an authorized account
and reserve time for teardown.

## Why the First Deployment Has Two Terraform Applies

The first deployment has a bootstrap problem:

```text
ECS needs an image in ECR before it can start a task.
CodeBuild needs the AWS build resources before it can create that image.
```

We solve it without local Docker:

```text
1. Terraform creates AWS resources with desired_count = 0
2. CodeBuild builds and pushes the first image
3. Terraform changes desired_count from 0 to 1
4. ECS starts the task from the image now stored in ECR
```

Later releases do not need the bootstrap step. A Git push can trigger CodeBuild
directly.

## Part A: Prepare the Student Repository

### A1. Open the Repository

```powershell
Set-Location C:\path\to\taxi-forecasting-student
.\.venv\Scripts\Activate.ps1
git status --short
```

### A2. Confirm the Repository Is in the Student's GitHub Account

CodeBuild clones from GitHub. Each student needs a GitHub repository they are
authorized to connect to CodeBuild.

Check the remote:

```powershell
git remote -v
git branch --show-current
```

The remote should point to the student's repository, not an instructor
repository they cannot administer.

Push the current branch:

```powershell
git push -u origin main
```

If the repository uses another deployment branch, record that branch and use
the same value for `deploy_branch`.

### A3. Confirm the Current Commit

```powershell
$Commit = (git rev-parse --short HEAD).Trim()
$Tag = "w5-$Commit"
$Tag
```

This connects:

```text
Git commit -> CodeBuild source -> ECR image tag -> ECS task definition
```

## Part B: Install and Check Local Tools

### B1. Required Tools

Local Docker is not required.

```powershell
aws --version
terraform version
git --version
.\.venv\Scripts\python.exe --version
```

### B2. Install Missing Windows Tools

```powershell
winget source update

winget install --exact --id Amazon.AWSCLI `
    --accept-package-agreements `
    --accept-source-agreements

winget install --exact --id Hashicorp.Terraform `
    --accept-package-agreements `
    --accept-source-agreements
```

Restart VS Code after installation so its terminals receive the updated PATH.

Do not install similarly named Python packages with `pip`.

## Part C: Authenticate to AWS

Use one authorized route.

### C1. AWS IAM Identity Center / SSO

```powershell
aws configure sso --profile week5-lab
aws sso login --profile week5-lab

$env:AWS_PROFILE = "week5-lab"
$env:AWS_REGION = "us-east-1"
$env:AWS_DEFAULT_REGION = "us-east-1"
```

### C2. Temporary AWS Lab Credentials

Place the temporary values in a local named profile:

```text
%USERPROFILE%\.aws\credentials
```

Use:

```text
[week5-lab]
aws_access_key_id=ENTER_LOCALLY
aws_secret_access_key=ENTER_LOCALLY
aws_session_token=ENTER_LOCALLY
```

Then:

```powershell
aws configure set region us-east-1 --profile week5-lab
aws configure set output json --profile week5-lab

$env:AWS_PROFILE = "week5-lab"
$env:AWS_REGION = "us-east-1"
$env:AWS_DEFAULT_REGION = "us-east-1"
```

Never put AWS credentials in Git, Terraform variables, documentation,
screenshots, or chat.

### C3. Privately Confirm Identity

```powershell
aws sts get-caller-identity
```

Privately confirm:

- the expected student AWS account;
- the expected role or user;
- the account is not a shared production account.

Do not expose the account ID or ARN.

### C4. Set the Region

```powershell
$Region = "us-east-1"
aws configure get region
```

The AWS Console must also be set to:

```text
US East (N. Virginia) / us-east-1
```

## Part D: Check AWS and Model Prerequisites

### D1. Confirm the Default VPC

The Terraform configuration uses the account's default VPC:

```powershell
aws ec2 describe-vpcs `
    --region $Region `
    --filters "Name=is-default,Values=true" `
    --query "Vpcs[].VpcId" `
    --output text
```

Stop if the result is empty.

Check the default subnets:

```powershell
aws ec2 describe-subnets `
    --region $Region `
    --filters "Name=default-for-az,Values=true" `
    --query "Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone}" `
    --output table
```

### D2. Confirm the Model Build Inputs

CodeBuild gets source code from GitHub, but the trained model files are not in
Git. They must exist locally before being uploaded to the CodeBuild S3 bucket.

```powershell
Get-Item .\mlflow.db
Get-Item .\data\processed\demand_hourly.parquet
Get-ChildItem .\mlruns | Select-Object -First 5
```

Required:

```text
mlflow.db
mlruns/
data/processed/demand_hourly.parquet
```

Stop if any are missing. Complete training and registration first.

### D3. Understand the Two Input Sources

```text
GitHub
  -> Python source, Terraform, Dockerfile, buildspec

S3 artifact bucket
  -> mlflow.db
  -> mlruns/
  -> demand_hourly.parquet

CodeBuild combines both
  -> self-contained Docker image
```

## Part E: Prepare GitHub Access for CodeBuild

Terraform creates:

- the CodeBuild project;
- the GitHub source connection;
- the GitHub webhook.

The current Terraform implementation expects an authorized GitHub personal
access token with access to the repository and permission to administer its
webhook.

For a classic token, the repository documents these scopes:

```text
repo
admin:repo_hook
```

Create the token directly in GitHub. Do not send it to the instructor or paste
it into chat.

Read it into the current PowerShell process without displaying it:

```powershell
$SecureToken = Read-Host "Enter the authorized GitHub token" -AsSecureString
$TokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
try {
    $env:TF_VAR_github_token =
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($TokenPointer)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($TokenPointer)
}
```

Terraform receives the value through:

```text
TF_VAR_github_token
```

Do not put it in `student.tfvars`.

## Part F: Create the Student CodeBuild Configuration

Create:

```text
infra\terraform\student-codebuild.tfvars
```

Use:

```hcl
aws_region   = "us-east-1"
project_name = "taxi-w5"
environment  = "student"

desired_count = 1
task_cpu      = 256
task_memory   = 512

enable_cicd       = true
github_repo_url   = "https://github.com/REPLACE_WITH_STUDENT/REPLACE_WITH_REPO.git"
deploy_branch     = "main"

enable_monitoring = false
enable_datalake   = false
enable_athena     = false
enable_dashboard  = false
```

Replace only the GitHub repository URL and, when necessary, the deployment
branch.

This creates:

```text
core API:
  ECR + ECS + Fargate + ALB + logs

release path:
  S3 artifact bucket + CodeBuild + GitHub webhook + IAM
```

It does not create the optional monitoring, data-lake, or dashboard stacks.

## Part G: Validate Before Creating Anything

```powershell
terraform -chdir=infra\terraform init -input=false
terraform -chdir=infra\terraform fmt student-codebuild.tfvars
terraform -chdir=infra\terraform fmt -check
terraform -chdir=infra\terraform validate
```

Validation proves structure, not AWS creation.

## Part H: Bootstrap AWS with Zero Running Tasks

### H1. Review the Bootstrap Plan

The command-line value overrides `desired_count=1` temporarily:

```powershell
$BootstrapPlan = Join-Path $env:TEMP "taxi-w5-codebuild-bootstrap.tfplan"

terraform -chdir=infra\terraform plan `
    -input=false `
    -out="$BootstrapPlan" `
    -var-file=student-codebuild.tfvars `
    -var "image_tag=$Tag" `
    -var "desired_count=0"
```

Check:

- resource prefix is `taxi-w5-student`;
- CodeBuild and the artifact bucket will be created;
- ECS desired count is zero;
- optional stacks are disabled;
- no unrelated delete action appears.

### H2. Apply the Bootstrap Plan

```powershell
terraform -chdir=infra\terraform apply `
    -input=false `
    "$BootstrapPlan"
```

At this point:

```text
AWS resources exist
ECS service exists
desired task count = 0
no application image has been built yet
```

This is expected.

## Part I: Upload Model Artifacts to the CodeBuild Bucket

Run:

```powershell
.\scripts\aws\upload_artifacts.ps1 -Region $Region
```

The script reads the artifact-bucket output and uploads:

```text
mlflow.db
mlruns/
demand_hourly.parquet
```

Verify only the object count or command success. Do not expose the private
bucket name in screenshots.

Re-run this upload whenever a newly trained model should enter the next image.

## Part J: Start the First CodeBuild Release

### J1. Read the CodeBuild Project Name

```powershell
$CodeBuildProject = (
    terraform -chdir=infra\terraform output -raw cicd_project_name
).Trim()
```

Do not expose the project ARN.

### J2. Start the Build

A manual CodeBuild start deploys by default in the current `buildspec.yml`:

```powershell
$Build = aws codebuild start-build `
    --region $Region `
    --project-name $CodeBuildProject |
    ConvertFrom-Json

$BuildId = $Build.build.id
```

Do not put the build ID in public evidence because it contains account-specific
context.

### J3. Wait for CodeBuild

```powershell
$TerminalStates = @(
    "SUCCEEDED",
    "FAILED",
    "FAULT",
    "STOPPED",
    "TIMED_OUT"
)

do {
    $BuildState = aws codebuild batch-get-builds `
        --region $Region `
        --ids $BuildId |
        ConvertFrom-Json

    $BuildStatus = $BuildState.builds[0].buildStatus
    Write-Host "CodeBuild status: $BuildStatus"

    if ($BuildStatus -notin $TerminalStates) {
        Start-Sleep -Seconds 15
    }
}
while ($BuildStatus -notin $TerminalStates)

if ($BuildStatus -ne "SUCCEEDED") {
    throw "CodeBuild failed with status $BuildStatus"
}
```

### J4. What the Build Does

```text
install
  -> install Python requirements

pre_build
  -> Ruff
  -> pytest + coverage

build
  -> download MLflow files from S3
  -> create portable mlflow.container.db
  -> Docker login to ECR
  -> Docker build inside CodeBuild
  -> Docker push commit-tagged image
  -> also publish latest when needed

post_build
  -> request ECS service update
```

The service still has desired count zero, so no API task starts yet.

### J5. Inspect Build Logs

AWS Console:

```text
CodeBuild
  -> Build projects
  -> taxi-w5-student-ci
  -> Build history
  -> latest build
```

Read the phase that failed. Do not rerun before understanding the error.

## Part K: Start the ECS Task

Now that the image exists in ECR, apply the real desired count from the variable
file:

```powershell
$RunPlan = Join-Path $env:TEMP "taxi-w5-codebuild-run.tfplan"

terraform -chdir=infra\terraform plan `
    -input=false `
    -out="$RunPlan" `
    -var-file=student-codebuild.tfvars `
    -var "image_tag=$Tag"

terraform -chdir=infra\terraform apply `
    -input=false `
    "$RunPlan"
```

This changes:

```text
desired_count: 0 -> 1
```

ECS can now pull the image CodeBuild pushed to ECR.

## Part L: Wait for ECS and Read Outputs

```powershell
$Cluster = (
    terraform -chdir=infra\terraform output -raw ecs_cluster_name
).Trim()

$Service = (
    terraform -chdir=infra\terraform output -raw ecs_service_name
).Trim()

$ApiUrl = (
    terraform -chdir=infra\terraform output -raw api_url
).Trim()
```

Wait:

```powershell
aws ecs wait services-stable `
    --region $Region `
    --cluster $Cluster `
    --services $Service
```

Check:

```powershell
aws ecs describe-services `
    --region $Region `
    --cluster $Cluster `
    --services $Service `
    --query "services[0].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}" `
    --output table
```

Expected:

```text
Status  = ACTIVE
Desired = 1
Running = 1
Pending = 0
```

## Part M: Prove the Correct Image Is Running

```powershell
$TaskDefinition = aws ecs describe-services `
    --region $Region `
    --cluster $Cluster `
    --services $Service `
    --query "services[0].taskDefinition" `
    --output text

aws ecs describe-task-definition `
    --region $Region `
    --task-definition $TaskDefinition `
    --query "taskDefinition.containerDefinitions[0].image" `
    --output text
```

The image reference should end with:

```text
:w5-<current-commit>
```

If the task definition references `latest`, confirm that CodeBuild published
the current commit image and the matching `latest` manifest before accepting
the release.

## Part N: Prove the API Is Ready

### N1. Health Body

```powershell
$Health = Invoke-RestMethod "$ApiUrl/health" -TimeoutSec 60
$Health | ConvertTo-Json -Depth 4
```

Require:

```text
status = ok
demand_model_loaded = true
fare_model_loaded = true
history_hours > 0
zones > 0
```

HTTP 200 alone is not sufficient because this application can return a degraded
body with HTTP 200.

### N2. Full Smoke Test

```powershell
.\.venv\Scripts\python.exe .\scripts\aws\verify_staging.py `
    --api-url $ApiUrl `
    --timeout 60
```

Expected:

```text
passed = true
process exit code = 0
```

The script checks:

- health;
- fare prediction;
- demand prediction;
- recursive forecast;
- explanations;
- metrics;
- invalid-input behavior.

### N3. Swagger

```powershell
Start-Process "$ApiUrl/docs"
```

Send one fare request and one demand request.

## Part O: Find the Flow in AWS Console

Use region:

```text
US East (N. Virginia) / us-east-1
```

| Console area | Evidence |
| --- | --- |
| CodeBuild | Successful build phases |
| S3 | Build-input objects exist |
| ECR | Commit-tagged image exists |
| ECS cluster | API service is active |
| ECS service | Desired 1, running 1 |
| ECS task | Expected image is running |
| EC2 > Load Balancers | ALB is active |
| Target groups | One target is healthy |
| CloudWatch Logs | Container startup and request logs |

Do not capture:

- account IDs;
- ARNs;
- private bucket names;
- ECR hostnames;
- role names;
- GitHub token;
- temporary credentials;
- personal email.

## Part P: Release the Next Code Change

After the first deployment, the webhook handles later releases.

### P1. Change, Check, Commit, and Push

```powershell
.\scripts\ci_local.ps1

git add "path\to\approved-file"
git commit -m "Describe the approved change"
git push origin main
```

The push starts:

```text
GitHub webhook
  -> CodeBuild
  -> Ruff + pytest
  -> Docker build
  -> ECR push
  -> ECS update request
```

### P2. Model-Only Release

After retraining locally:

```powershell
.\scripts\aws\upload_artifacts.ps1 -Region $Region
```

Then start an approved CodeBuild release or push the corresponding repository
revision. Uploading artifacts alone does not update ECS.

### P3. Pull Requests

The declared webhook route runs checks for pull requests. The buildspec should
not deploy a pull-request build because it is not the deployment branch.

## Part Q: Teardown

Teardown is mandatory.

The same GitHub token environment variable is required while
`enable_cicd=true` remains in the Terraform configuration.

### Q1. Review the Destroy Plan

```powershell
terraform -chdir=infra\terraform plan `
    -destroy `
    -input=false `
    -var-file=student-codebuild.tfvars `
    -var "image_tag=$Tag"
```

Confirm it targets only `taxi-w5-student` resources.

### Q2. Destroy

```powershell
terraform -chdir=infra\terraform destroy `
    -input=false `
    -auto-approve `
    -var-file=student-codebuild.tfvars `
    -var "image_tag=$Tag"
```

This removes the Terraform-managed:

- CodeBuild project;
- GitHub webhook registration;
- S3 artifact bucket and uploaded build inputs;
- ECR repository and images;
- ECS service, task definition, and cluster;
- ALB and target group;
- log groups;
- IAM roles and security groups.

### Q3. Verify Empty State

```powershell
terraform -chdir=infra\terraform show
```

Expected:

```text
The state file is empty. No resources are represented.
```

### Q4. Clear Secrets and Profile Selection

```powershell
Remove-Item Env:TF_VAR_github_token -ErrorAction SilentlyContinue
Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
Remove-Item Env:AWS_REGION -ErrorAction SilentlyContinue
Remove-Item Env:AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
```

Revoke the temporary GitHub token when the exercise is complete if it was
created only for this lab.

Remove only the temporary `week5-lab` AWS profile. Do not delete unrelated
profiles.

## Troubleshooting

| Problem | First check |
| --- | --- |
| AWS CLI is not recognized | Install it and restart VS Code |
| Terraform is not recognized | Install it and restart the terminal |
| `Unable to locate credentials` | Set `AWS_PROFILE`; run `aws sts get-caller-identity` |
| `ExpiredToken` | Repeat SSO login or refresh lab credentials |
| Terraform says `github_token` is required | Set `TF_VAR_github_token` in the current terminal |
| GitHub credential or webhook creation fails | Confirm repository ownership and token permissions |
| Default VPC not found | Use an instructor-prepared account/configuration |
| Artifact upload says file missing | Complete model training and registration |
| CodeBuild cannot download S3 objects | Check upload success and CodeBuild IAM policy |
| CodeBuild fails at Ruff or pytest | Fix the code; do not bypass the quality gate |
| CodeBuild fails at Docker build | Read the first Docker error and confirm all downloaded files |
| CodeBuild cannot push ECR | Check its service role and repository policy |
| ECS stays at running zero | Read ECS service events and container logs |
| ALB returns 503 | Wait for a healthy target; inspect task startup |
| `/health` is degraded | Read CloudWatch logs for model or history loading failure |

### Read ECS Service Events

```powershell
aws ecs describe-services `
    --region $Region `
    --cluster $Cluster `
    --services $Service `
    --query "services[0].events[0:10].[createdAt,message]" `
    --output table
```

## Safe Evidence Checklist

Record:

- Git commit;
- CodeBuild status and phase names;
- image tag without account hostname;
- ECS desired/running counts;
- target health;
- sanitized `/health` body;
- smoke-test summary;
- empty Terraform state after teardown.

Redact:

- account ID;
- ARN;
- IAM identity;
- CodeBuild build ID;
- S3 bucket name;
- ECR hostname;
- ALB hostname;
- GitHub token;
- AWS credentials;
- personal email.

## Completion Checklist

- [ ] Student GitHub repository and deployment branch confirmed.
- [ ] AWS identity and region confirmed privately.
- [ ] AWS CLI, Terraform, Git, and Python available.
- [ ] Model build inputs present.
- [ ] GitHub token entered only through the terminal environment.
- [ ] Bootstrap apply completed with desired count zero.
- [ ] Model artifacts uploaded to S3.
- [ ] First CodeBuild run succeeded.
- [ ] Final apply changed desired count to one.
- [ ] ECS desired/running is 1/1.
- [ ] Health body says `ok`.
- [ ] Smoke tests pass.
- [ ] Later push-to-CodeBuild flow understood.
- [ ] Terraform destroy completed.
- [ ] Local Terraform state is empty.
- [ ] Temporary credentials and token cleared.
