# Jenkins Templates for AWS CloudFormation

Find the documentation here: https://templates.cloudonaut.io/en/stable/jenkins/

## Developer notes

### RegionMap
To update the region map execute the following lines in your terminal:

```
$ regions=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text)
$ for region in $regions; do ami=$(aws --region $region ec2 describe-images --filters "Name=name,Values=amzn2-ami-hvm-2.0.20191116.0-x86_64-gp2" --query "Images[0].ImageId" --output "text"); printf "'$region':\n  AMI: '$ami'\n"; done
```

### Deploying
There are two stacks that need to be deployed:

1. VPC
     
        aws cloudformation deploy \
            --template-file "./../vpc/vpc-2azs.yaml" \
            --capabilities CAPABILITY_IAM \
            --s3-bucket "jenkins-cf-templates-***REMOVED***" \
            --stack-name "jenins-vpc"

2. Jenkins
   
        aws cloudformation deploy \
            --template-file "./jenkins2-ha-agents.yaml" \
            --capabilities CAPABILITY_IAM \
            --s3-bucket "jenkins-cf-templates-***REMOVED***" \
            --parameter-overrides \
                CIDRWhiteList="$(dig +short myip.opendns.com @resolver1.opendns.com)/32" \
                KeyName="spargo-control" \
                MasterAdminPassword="my_password_here" \
                ParentVPCStack="jenkins-vpc" \
            --stack-name "jenkins-resources"

    Parameters:
    
        CIDRWhiteList = One CIDR block that acts as a whitelist. This will be changed to accept a Security Group instead.
        KeyName = The name of the key pair created via the EC2 panel. The existing one is named `spargo-control`.
        MasterAdminPassword = Password for Jenkins.
        ParentVPCStack = Name of the VPC stack which is 'jenkins-vpc' in the above example.
        
The stack takes ~10 minutes to build and it will only allow your current IP. If your IP changes, you'll have to update the stack to allow your new CIDR block.
