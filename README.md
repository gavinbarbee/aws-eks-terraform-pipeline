# AWS EKS Platform with Terraform and GitHub Actions

**Status:** ✅ Complete

## Video Walkthrough

> Loom walkthrough coming soon.

## Project Overview

I built a container platform on AWS that deploys entirely through GitHub Actions. Terraform provisions a VPC and an Amazon EKS cluster behind a Checkov security gate, with every apply waiting for my approval on a saved plan. A second workflow builds the app image, pushes it to Amazon ECR tagged with the commit SHA, and ships it to EKS with Helm. The pipeline authenticates to AWS through OIDC federation, so no AWS access keys are stored in GitHub.

Once the platform is running, I test it the way a production team would: I load the app until the Horizontal Pod Autoscaler adds pods, then push a broken release and roll it back with Helm.

This is the AWS rebuild of my [Azure Terraform DevSecOps pipeline](https://github.com/gavinbarbee/azure-terraform-devsecops-pipeline), carrying the same OIDC, security-gate, and approval patterns across clouds.

### Skills Demonstrated

- **AWS networking:** VPC with public and private subnets across two Availability Zones, NAT gateway, and subnet tagging for Kubernetes load balancers
- **Amazon EKS:** managed node group on Amazon Linux 2023, EKS access entries for cluster-admin, core add-ons
- **Infrastructure as code:** Terraform with registry modules, S3 remote state with native locking, saved-plan workflow
- **CI/CD:** GitHub Actions with OIDC federation to AWS, Checkov gate with SARIF upload to code scanning, environment approval before apply
- **Containers:** Docker image built on a non-root NGINX base, pushed to Amazon ECR with immutable tags and scan-on-push
- **Kubernetes operations:** Helm chart with probes, resource limits, hardened security context, Horizontal Pod Autoscaler, and Helm rollback

## Architecture Diagram

```mermaid
flowchart LR
    dev[Developer] -->|PR / push| gh[GitHub repository]

    subgraph actions[GitHub Actions]
        ck[Checkov gate] --> plan[Terraform plan]
        plan --> appr{dev approval}
        appr --> apply[Terraform apply]
        build[Docker build] --> push[Push to ECR]
        push --> helm[Helm deploy]
    end

    gh --> ck
    gh --> build
    actions -->|OIDC| iam[IAM role<br>role-gavinbarbee-github-actions-eks]

    subgraph aws[AWS us-east-1]
        s3[(S3 remote state)]
        ecr[(ECR<br>gavinbarbee-listings)]
        subgraph vpc[vpc-gavinbarbee-eks]
            subgraph pub[Public subnets]
                lb[Load balancer]
                nat[NAT gateway]
            end
            subgraph priv[Private subnets]
                eks[EKS cluster<br>eks-gavinbarbee-dev]
                pods[listings pods + HPA]
            end
        end
    end

    apply --> s3
    apply --> eks
    push --> ecr
    helm --> pods
    ecr --> pods
    user[User] --> lb --> pods
```

## Prerequisites

- AWS account (I used my AWS Organizations management account) with the AWS CLI v2 and an `admin` profile for an IAM user with AdministratorAccess
- Terraform 1.10 or later (needed for S3 native state locking)
- kubectl and Helm for local verification
- GitHub CLI (`gh`) signed in to my account
- Windows with PowerShell and VS Code

> **Cost note:** EKS bills about $0.10/hour for the control plane, plus two t3.medium nodes, a NAT gateway, and a load balancer. My estimate is roughly $6–8/day, so I tear it down as soon as I finish testing.

## Naming Conventions

| Resource | Name |
|---|---|
| GitHub repo | gavinbarbee/aws-eks-terraform-pipeline |
| State bucket | gavinbarbee-eks-tfstate-&lt;random suffix&gt; |
| GitHub Actions IAM role | role-gavinbarbee-github-actions-eks |
| VPC | vpc-gavinbarbee-eks |
| EKS cluster | eks-gavinbarbee-dev |
| Node group | default |
| ECR repository | gavinbarbee-listings |
| Helm release | listings |
| GitHub environment | dev |

## Project Steps

### 1. Create the project folder and repo

```powershell
cd $HOME\Desktop
mkdir aws-eks-terraform-pipeline
cd aws-eks-terraform-pipeline
git init -b main
```

I added the files from this repo, then created the GitHub repo:

```powershell
gh repo create gavinbarbee/aws-eks-terraform-pipeline --public `
  --description "AWS EKS platform with Terraform and GitHub Actions: OIDC auth, Checkov gate, ECR, Helm, autoscaling, and rollback" `
  --source . --remote origin
```

### 2. Sign in to AWS and get my admin ARN

I created an IAM user, `gavinbarbee-admin`, with the AdministratorAccess policy, created an access key for it, and saved the key as a named CLI profile:

```powershell
aws configure --profile admin
$env:AWS_PROFILE = "admin"
```

I set `$env:AWS_PROFILE = "admin"` in every terminal before running AWS, Terraform, kubectl, or Helm commands.

EKS access entries need my IAM principal ARN. Because I'm signed in as an IAM user and not an assumed role, `sts get-caller-identity` returns the user ARN directly, and I can use it with no conversion:

```powershell
aws sts get-caller-identity
$adminArn = aws sts get-caller-identity --query Arn --output text
$adminArn
```

![Caller identity for the admin IAM user](screenshots/02-caller-identity.png)

### 3. Bootstrap the state bucket and OIDC role

The bootstrap stack runs locally once. It creates the S3 state bucket, the GitHub OIDC provider, and the IAM role the pipeline assumes.

```powershell
cd bootstrap
terraform init
terraform plan "-out=main.tfplan"
terraform apply main.tfplan
cd ..
```

![Bootstrap apply output](screenshots/03-bootstrap-apply.png)

### 4. Store pipeline settings as GitHub variables

None of these values are secrets, but I keep them out of the code:

```powershell
gh variable set AWS_REGION --body "us-east-1"
gh variable set AWS_ROLE_ARN --body (terraform -chdir=bootstrap output -raw github_actions_role_arn)
gh variable set TF_STATE_BUCKET --body (terraform -chdir=bootstrap output -raw state_bucket)
gh variable set ADMIN_PRINCIPAL_ARN --body $adminArn
gh variable list
```

![GitHub Actions variables](screenshots/04-github-variables.png)

### 5. Create the dev environment approval gate

In GitHub: **Settings → Environments → New environment → `dev`**, then I enabled **Required reviewers** and added myself. The apply job pauses here until I approve.

![dev environment with required reviewer](screenshots/05-dev-environment.png)

### 6. Open a pull request to run the security gate and plan

```powershell
git checkout -b feature/eks-platform
git status
git add .
git commit -m "feat: VPC, EKS, ECR, Helm chart, and pipelines"
git push -u origin feature/eks-platform
gh pr create --fill
```

Checkov scans the Terraform first. Results go to **Security → Code scanning** as SARIF, and the plan appears in the run summary.

![Checkov gate and plan passing on the PR](screenshots/06-pr-checkov-and-plan.png)

![Terraform plan summary: 61 to add](screenshots/06-plan-61-to-add.png)

### 7. Merge and approve the apply

```powershell
gh pr merge --squash --delete-branch
git checkout main
git pull
```

The push to main produces a saved plan, then waits on the `dev` environment. I approved it in the Actions tab. EKS creation takes about 15 minutes.

![Approval gate on the dev environment](screenshots/07-approval-gate.png)

![Successful Terraform apply](screenshots/07-terraform-apply.png)

### 8. Connect kubectl from my machine

```powershell
aws eks update-kubeconfig --region us-east-1 --name eks-gavinbarbee-dev
kubectl get nodes
```

![Two Ready nodes](screenshots/08-kubectl-nodes.png)

![EKS cluster overview](screenshots/08-eks-cluster-overview.png)

![EKS access entries](screenshots/08-eks-access-entries.png)

### 9. Deploy the app

```powershell
gh workflow run deploy.yml
gh run watch
```

The workflow builds the image, pushes it to ECR tagged with the commit SHA, installs metrics-server, and runs `helm upgrade --install`. Then I checked the release and opened the load balancer address:

```powershell
kubectl get pods,svc,hpa
$lb = kubectl get svc listings -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
Start-Process "http://$lb"
```

![Deploy workflow run](screenshots/09-deploy-run.png)
![Listings page in the browser](screenshots/09-listings-page.png)

### 10. Test autoscaling under load

In one terminal I watched the autoscaler:

```powershell
kubectl get hpa listings --watch
```

In a second terminal I generated load from inside the cluster:

```powershell
kubectl run load-generator --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://listings > /dev/null; done"
```

Once CPU passed the 50% target, the HPA scaled the deployment above 2 replicas. Then I stopped the load and watched it scale back down:

```powershell
kubectl delete pod load-generator
```

![HPA scaling up under load](screenshots/10-hpa-scale-up.png)

### 11. Push a bad release and roll it back

I deployed a release that points to an image tag that doesn't exist, which simulates a broken deploy:

```powershell
helm upgrade listings helm/listings --reuse-values --set image.tag=does-not-exist
kubectl get pods
```

The new pods failed with `ImagePullBackOff`, and the old pods kept serving traffic because the new ones never passed readiness. Then I rolled back:

```powershell
helm history listings
helm rollback listings
kubectl get pods
```

![ImagePullBackOff on the bad release](screenshots/11-bad-release.png)

![helm history after rollback](screenshots/11-rollback-history.png)

## Verification Checklist

- [ ] Bootstrap created the state bucket, OIDC provider, and IAM role
- [ ] No AWS access keys stored anywhere in GitHub
- [ ] Checkov results visible in code scanning
- [ ] Apply waited for my approval on the `dev` environment
- [ ] `kubectl get nodes` shows 2 Ready nodes
- [ ] Image in ECR tagged with the commit SHA, with a scan result
- [ ] Listings page loads from the load balancer address
- [ ] HPA scaled up under load and back down after
- [ ] Bad release failed without taking the site down, and `helm rollback` restored it

## Troubleshooting

| Issue | Cause | Fix |
|---|---|---|
| `InvalidClientTokenId` on every AWS CLI call, and IAM Identity Center sign-in failing through Entra ID | My old long-lived access keys were deactivated, and the Identity Center sign-in through my Entra ID federation wouldn't complete | Created a dedicated IAM user (`gavinbarbee-admin`) with AdministratorAccess, saved its keys with `aws configure --profile admin`, and set `$env:AWS_PROFILE = "admin"` |
| Checkov failed with `CKV_AWS_394` on the `aws_availability_zones` data source | Looking up zones by name means a change in the returned zone list could shift subnets to different zones | Pinned the zone IDs `use1-az1` and `use1-az2` instead of looking up zone names |
| `AssumeRoleWithWebIdentity` denied in GitHub Actions | The repo uses GitHub immutable subject claims, so the OIDC token's `sub` includes the owner and repo IDs, not just the names | Updated the trust policy `sub` condition to match the owner and repo IDs |
| **Review deployments** button missing on the waiting apply job | **Prevent self-review** was on for the `dev` environment, and I'm the only reviewer and the one who triggered the run | Unchecked **Prevent self-review** on the `dev` environment |

![Re-applying the bootstrap stack after updating the trust policy sub for immutable OIDC claims](screenshots/06-oidc-trust-fix-apply.png)

Re-applying the bootstrap stack after updating the trust policy sub for immutable OIDC claims.

## Cleanup

The load balancer must be removed before Terraform destroys the VPC, or the destroy hangs on its network interfaces. I uninstalled the Helm releases first, then confirmed the service and its load balancer were gone:

```powershell
$env:AWS_PROFILE = "admin"
helm uninstall listings
helm uninstall metrics-server --namespace kube-system
kubectl get svc
aws elb describe-load-balancers --query "LoadBalancerDescriptions[].LoadBalancerName"
```

Then I destroyed the platform stack with a saved plan (61 to destroy):

```powershell
cd terraform
terraform init -backend-config="bucket=$(terraform -chdir=..\bootstrap output -raw state_bucket)"
terraform plan -destroy -var "admin_principal_arn=$adminArn" "-out=destroy.tfplan"
terraform apply destroy.tfplan
cd ..
```

I kept the bootstrap stack (state bucket, OIDC provider, and IAM role) because the follow-up labs in this series reuse it. When the series is finished, the last step is to destroy it too:

```powershell
cd bootstrap
terraform plan -destroy "-out=destroy.tfplan"
terraform apply destroy.tfplan
cd ..
```

## Key Takeaways

- **Security gates catch real problems, not just style issues.** Checkov flagged CKV_AWS_394 on my availability zone lookup. If AWS had ever reordered the zone list, Terraform would have tried to replace my subnets and cluster networking. Pinning zone IDs (use1-az1, use1-az2) instead of zone names fixed it, and zone IDs also map to the same physical zones in every account.
- **OIDC trust policies have to match the exact token GitHub sends.** My repo uses GitHub's immutable subject claims, so the sub includes the owner and repo IDs, not just the names. The fix was stricter than the original policy: the role now trusts this exact repo, so a renamed or recreated repo with the same name can't assume it. CloudTrail showed me the exact sub GitHub sent, which made the mismatch obvious.
- **Approval gates are only as strong as their settings.** Turning off admin bypass meant every apply needed my review, with no exceptions. Prevent self-review blocked me as the only reviewer, which showed me how that setting works on a real team: the person who triggers a deploy can't approve it.
- **Kubernetes protects users from bad deploys when the basics are in place.** When I pushed a release with an image that didn't exist, the new pod failed with ImagePullBackOff while the old pods kept serving traffic, because readiness probes and the rolling update held the broken pod out of rotation. helm rollback restored the working release in seconds.
- **Patterns carry across clouds.** This was a rebuild of my Azure DevSecOps pipeline on AWS. OIDC federation, a security gate before plan, and approval before a saved-plan apply all worked the same way. Only the provider details changed: IAM roles instead of federated credentials, and S3 native locking instead of a blob lease.
- **Check support dates before picking a version.** I confirmed Kubernetes 1.35 was in EKS standard support until March 2027 before building, because a version in extended support costs six times as much for the control plane.

---

*Built by Gavin Barbee · Time to complete: about 1.5 hours*
