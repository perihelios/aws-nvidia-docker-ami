#!/bin/bash -eu
set -o pipefail

. settings.conf

# Note: AWS region *MUST* be us-east-1 to publish AMI to Marketplace!
AWS_REGION=us-east-1

fail() {
	local message="$1"
	local logFile=""

	if [ $# -ge 2 ]; then
		logFile="$2"
	fi

	echo "ERROR: $message (line ${BASH_LINENO[0]})" >&2

	if [ -f "$logFile" ]; then
		echo -e "\nContent of ${logFile}:\n" >&2
		cat "$logFile" >&2
	fi

	exit 1
}

randomHex() {
	dd if=/dev/urandom bs=1 count=4 2>/dev/null | od -t x4 -A n | sed 's/ //g'
}

cleanup() {
	if [ -n "$KEY_NAME" ]; then
		aws --region "$AWS_REGION" ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null >&2 || true
	fi

#	if [ -n "$CF_STACK_NAME" ]; then
#		aws --region "$AWS_REGION" cloudformation delete-stack --stack-name "$CF_STACK_NAME" >/dev/null >&2 || true
#	fi
}

trap cleanup EXIT

mkdir temp || fail "Failed to create temp directory"

MY_IP_ADDRESS=$(curl -sS --fail --connect-timeout 15 https://httpbin.org/ip 2>"temp/my-ip-address.log" | jq -r .origin) ||
	fail "Failed to obtain external IP address for your computer" "temp/my-ip-address.log"

if [[ ! "$MY_IP_ADDRESS" =~ [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3} ]]; then
	fail "Bad external IP address obtained for your computer: $MY_IP_ADDRESS"
fi

RANDOM_HEX=$(randomHex)
CF_STACK_NAME="nvidia-docker-ami-builder-$RANDOM_HEX"
KEY_NAME="$CF_STACK_NAME"

ssh-keygen -t rsa -b 2048 -f "temp/key" -N '' -C ubuntu >"temp/ssh-keygen.log" 2>&1 ||
	fail "Failed to generate SSH key" "temp/ssh-keygen.log"

aws --region "$AWS_REGION" --output json ec2 import-key-pair \
	--key-name "$KEY_NAME" \
	--public-key-material "$(cat temp/key.pub)" \
	>"temp/aws-import-key-pair.log" 2>&1 || fail "Failed to import SSH public key to AWS" "temp/aws-import-key-pair.log"

aws --region "$AWS_REGION" --output json cloudformation create-stack \
	--stack-name "$CF_STACK_NAME" \
	--template-body "$(cat cloudformation.json)" \
	--parameters \
		ParameterKey=VpcCidrBlock,ParameterValue="$VPC_CIDR_BLOCK" \
		ParameterKey=SshIngressIpAddress,ParameterValue="$MY_IP_ADDRESS" \
		ParameterKey=Ami,ParameterValue="$BASE_AMI_ID" \
		ParameterKey=KeyPairName,ParameterValue="$CF_STACK_NAME" \
	--on-failure DELETE \
	>"temp/create-stack.log" 2>&1 || fail "Failed to create CloudFormation stack" "temp/create-stack.log"

pollForCloudFormationOutputs() {
	local stackName="$1"
	local waitMinutes=5
	local intervalSeconds=30
	local attempts=$((waitMinutes * 60 / intervalSeconds))

	while [ $attempts -gt 0 ]; do
		let attempts--

		local json=$(aws --region "$AWS_REGION" --output json cloudformation describe-stacks \
			--stack-name "$CF_STACK_NAME" \
			2>"temp/aws-describe-stacks.log"
		) || fail "Failed to describe CloudFormation stack" "temp/aws-describe-stacks.log"

		local state=$(jq -r '.Stacks[0].StackStatus' <<<"$json")
		case "$state" in
			CREATE_COMPLETE)
				jq '.Stacks[0].Outputs' <<<"$json"
				return
				;;
			CREATE_IN_PROGRESS)
				;;
			*)
				fail "Unexpected CloudFormation stack status: $state"
				;;
		esac

		sleep $intervalSeconds
	done
}

json=$(pollForCloudFormationOutputs "$CF_STACK_NAME")
INSTANCE_IP_ADDRESS=$(jq -r '.[] | select(.OutputKey == "InstanceIpAddress") | .OutputValue' <<<"$json")

sftp \
	-i "temp/key" \
	-b - \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	"ubuntu@$INSTANCE_IP_ADDRESS" \
	<<<'
		put inside-instance.sh
		put settings.conf
	' >"temp/sftp.log" 2>&1 ||
		fail "Failed to upload script to instance" "temp/sftp.log"

ssh \
	-i "temp/key" \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	"ubuntu@$INSTANCE_IP_ADDRESS" \
	'sudo /home/ubuntu/inside-instance.sh' \
	>"temp/ssh-command.log" 2>&1 ||
		fail "Failed to execute script on instance" "temp/ssh-command.log"

