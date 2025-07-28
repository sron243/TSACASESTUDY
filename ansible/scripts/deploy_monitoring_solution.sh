#!/bin/bash

# AWS Cloud-Based Disk Monitoring Solution Deployment Script
# This script deploys the complete monitoring infrastructure across multiple AWS accounts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ANSIBLE_DIR="$PROJECT_ROOT/ansible"
CLOUDFORMATION_DIR="$PROJECT_ROOT/ansible/cloudformation"

# Default values
ENVIRONMENT="production"
AWS_REGION="us-east-1"
ALERT_EMAIL="admin@company.com"
SLACK_WEBHOOK_URL=""
PAGERDUTY_API_KEY=""
MONITORED_ACCOUNTS=""
CROSS_ACCOUNT_ROLE_NAME="DiskMonitoringRole"
DISK_THRESHOLD_WARNING=80
DISK_THRESHOLD_CRITICAL=90
DISK_THRESHOLD_EMERGENCY=95
MONITORING_INTERVAL=300
VERBOSE=false
DRY_RUN=false

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

AWS Cloud-Based Disk Monitoring Solution Deployment Script

OPTIONS:
    -e, --environment ENV        Environment (production|staging|development) [default: production]
    -r, --region REGION          AWS region [default: us-east-1]
    -a, --accounts ACCOUNTS      Comma-separated list of AWS account IDs to monitor
    -m, --email EMAIL            Alert email address [default: admin@company.com]
    -s, --slack URL              Slack webhook URL (optional)
    -p, --pagerduty KEY          PagerDuty API key (optional)
    -w, --warning THRESHOLD      Warning threshold percentage [default: 80]
    -c, --critical THRESHOLD     Critical threshold percentage [default: 90]
    -u, --emergency THRESHOLD    Emergency threshold percentage [default: 95]
    -i, --interval SECONDS       Monitoring interval in seconds [default: 300]
    -v, --verbose                Enable verbose output
    -d, --dry-run                Perform a dry run without making changes
    -h, --help                   Display this help message

EXAMPLES:
    # Deploy to production environment
    $0 -e production -a "123456789012,234567890123" -m "admin@company.com"

    # Deploy with custom thresholds
    $0 -e staging -w 75 -c 85 -u 95 -i 600

    # Dry run to validate configuration
    $0 -e development -d -v

EOF
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check if Ansible is installed
    if ! command -v ansible &> /dev/null; then
        print_error "Ansible is not installed. Please install it first."
        exit 1
    fi
    
    # Check if AWS credentials are configured
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials are not configured. Please run 'aws configure' first."
        exit 1
    fi
    
    # Check if required directories exist
    if [[ ! -d "$ANSIBLE_DIR" ]]; then
        print_error "Ansible directory not found: $ANSIBLE_DIR"
        exit 1
    fi
    
    if [[ ! -d "$CLOUDFORMATION_DIR" ]]; then
        print_error "CloudFormation directory not found: $CLOUDFORMATION_DIR"
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Function to validate configuration
validate_configuration() {
    print_status "Validating configuration..."
    
    # Validate environment
    if [[ ! "$ENVIRONMENT" =~ ^(production|staging|development)$ ]]; then
        print_error "Invalid environment: $ENVIRONMENT"
        exit 1
    fi
    
    # Validate thresholds
    if [[ $DISK_THRESHOLD_WARNING -ge $DISK_THRESHOLD_CRITICAL ]]; then
        print_error "Warning threshold must be less than critical threshold"
        exit 1
    fi
    
    if [[ $DISK_THRESHOLD_CRITICAL -ge $DISK_THRESHOLD_EMERGENCY ]]; then
        print_error "Critical threshold must be less than emergency threshold"
        exit 1
    fi
    
    # Validate monitoring interval
    if [[ $MONITORING_INTERVAL -lt 60 ]]; then
        print_error "Monitoring interval must be at least 60 seconds"
        exit 1
    fi
    
    # Validate email format
    if [[ ! "$ALERT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        print_error "Invalid email format: $ALERT_EMAIL"
        exit 1
    fi
    
    print_success "Configuration validation passed"
}

# Function to deploy CloudFormation stack
deploy_cloudformation_stack() {
    print_status "Deploying CloudFormation stack..."
    
    local stack_name="disk-monitoring-${ENVIRONMENT}"
    local template_file="$CLOUDFORMATION_DIR/monitoring_stack.yml"
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$AWS_REGION" &> /dev/null; then
        print_status "Stack exists, updating..."
        aws cloudformation update-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters \
                ParameterKey=Environment,ParameterValue="$ENVIRONMENT" \
                ParameterKey=MonitoringNamespace,ParameterValue="DiskMonitoring" \
                ParameterKey=AlertEmail,ParameterValue="$ALERT_EMAIL" \
                ParameterKey=SlackWebhookUrl,ParameterValue="$SLACK_WEBHOOK_URL" \
                ParameterKey=PagerDutyApiKey,ParameterValue="$PAGERDUTY_API_KEY" \
                ParameterKey=MonitoredAccounts,ParameterValue="$MONITORED_ACCOUNTS" \
                ParameterKey=CrossAccountRoleName,ParameterValue="$CROSS_ACCOUNT_ROLE_NAME" \
                ParameterKey=DiskThresholdWarning,ParameterValue="$DISK_THRESHOLD_WARNING" \
                ParameterKey=DiskThresholdCritical,ParameterValue="$DISK_THRESHOLD_CRITICAL" \
                ParameterKey=DiskThresholdEmergency,ParameterValue="$DISK_THRESHOLD_EMERGENCY" \
                ParameterKey=MonitoringInterval,ParameterValue="$MONITORING_INTERVAL" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$AWS_REGION"
    else
        print_status "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name "$stack_name" \
            --template-body "file://$template_file" \
            --parameters \
                ParameterKey=Environment,ParameterValue="$ENVIRONMENT" \
                ParameterKey=MonitoringNamespace,ParameterValue="DiskMonitoring" \
                ParameterKey=AlertEmail,ParameterValue="$ALERT_EMAIL" \
                ParameterKey=SlackWebhookUrl,ParameterValue="$SLACK_WEBHOOK_URL" \
                ParameterKey=PagerDutyApiKey,ParameterValue="$PAGERDUTY_API_KEY" \
                ParameterKey=MonitoredAccounts,ParameterValue="$MONITORED_ACCOUNTS" \
                ParameterKey=CrossAccountRoleName,ParameterValue="$CROSS_ACCOUNT_ROLE_NAME" \
                ParameterKey=DiskThresholdWarning,ParameterValue="$DISK_THRESHOLD_WARNING" \
                ParameterKey=DiskThresholdCritical,ParameterValue="$DISK_THRESHOLD_CRITICAL" \
                ParameterKey=DiskThresholdEmergency,ParameterValue="$DISK_THRESHOLD_EMERGENCY" \
                ParameterKey=MonitoringInterval,ParameterValue="$MONITORING_INTERVAL" \
            --capabilities CAPABILITY_NAMED_IAM \
            --region "$AWS_REGION"
    fi
    
    # Wait for stack to complete
    print_status "Waiting for CloudFormation stack to complete..."
    aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$AWS_REGION" 2>/dev/null || \
    aws cloudformation wait stack-create-complete --stack-name "$stack_name" --region "$AWS_REGION"
    
    print_success "CloudFormation stack deployment completed"
}

# Function to deploy Lambda function
deploy_lambda_function() {
    print_status "Deploying Lambda function..."
    
    local lambda_name="disk-monitoring-collector-${ENVIRONMENT}"
    local lambda_file="$PROJECT_ROOT/ansible/scripts/disk_monitoring_lambda.py"
    
    # Create deployment package
    local temp_dir=$(mktemp -d)
    cp "$lambda_file" "$temp_dir/"
    
    # Create requirements.txt for dependencies
    cat > "$temp_dir/requirements.txt" << EOF
boto3>=1.26.0
botocore>=1.29.0
EOF
    
    # Install dependencies
    pip install -r "$temp_dir/requirements.txt" -t "$temp_dir/" --quiet
    
    # Create deployment package
    cd "$temp_dir"
    zip -r lambda_deployment.zip . > /dev/null
    cd - > /dev/null
    
    # Get function ARN from CloudFormation outputs
    local function_arn=$(aws cloudformation describe-stacks \
        --stack-name "disk-monitoring-${ENVIRONMENT}" \
        --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionArn'].OutputValue" \
        --output text)
    
    if [[ -n "$function_arn" ]]; then
        # Update function code
        aws lambda update-function-code \
            --function-name "$function_arn" \
            --zip-file "fileb://$temp_dir/lambda_deployment.zip" \
            --region "$AWS_REGION"
        
        print_success "Lambda function updated"
    else
        print_error "Could not find Lambda function ARN"
        exit 1
    fi
    
    # Clean up
    rm -rf "$temp_dir"
}

# Function to run Ansible playbooks
run_ansible_playbooks() {
    print_status "Running Ansible playbooks..."
    
    cd "$ANSIBLE_DIR"
    
    # Set environment variables for Ansible
    export ANSIBLE_HOST_KEY_CHECKING=False
    export AWS_DEFAULT_REGION="$AWS_REGION"
    
    # Create inventory file with current configuration
    cat > "inventories/current_config.yml" << EOF
---
# Current deployment configuration
environment: $ENVIRONMENT
aws_region: $AWS_REGION
alert_email: $ALERT_EMAIL
disk_threshold_warning: $DISK_THRESHOLD_WARNING
disk_threshold_critical: $DISK_THRESHOLD_CRITICAL
disk_threshold_emergency: $DISK_THRESHOLD_EMERGENCY
monitoring_interval: $MONITORING_INTERVAL
monitored_accounts: $MONITORED_ACCOUNTS
cross_account_role_name: $CROSS_ACCOUNT_ROLE_NAME
EOF
    
    # Run deployment playbook
    if [[ "$DRY_RUN" == true ]]; then
        print_status "Performing dry run..."
        ansible-playbook \
            -i inventories/aws_accounts.yml \
            playbooks/deploy_monitoring.yml \
            --check \
            --diff \
            --extra-vars "@inventories/current_config.yml"
    else
        ansible-playbook \
            -i inventories/aws_accounts.yml \
            playbooks/deploy_monitoring.yml \
            --extra-vars "@inventories/current_config.yml"
    fi
    
    cd - > /dev/null
    
    print_success "Ansible playbooks completed"
}

# Function to verify deployment
verify_deployment() {
    print_status "Verifying deployment..."
    
    local stack_name="disk-monitoring-${ENVIRONMENT}"
    
    # Check CloudFormation stack status
    local stack_status=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query "Stacks[0].StackStatus" \
        --output text)
    
    if [[ "$stack_status" == "CREATE_COMPLETE" || "$stack_status" == "UPDATE_COMPLETE" ]]; then
        print_success "CloudFormation stack is healthy: $stack_status"
    else
        print_error "CloudFormation stack is not healthy: $stack_status"
        exit 1
    fi
    
    # Check Lambda function
    local function_arn=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionArn'].OutputValue" \
        --output text)
    
    if [[ -n "$function_arn" ]]; then
        local function_config=$(aws lambda get-function --function-name "$function_arn" --region "$AWS_REGION")
        print_success "Lambda function is deployed: $function_arn"
    fi
    
    # Check SNS topic
    local sns_topic_arn=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='SNSTopicArn'].OutputValue" \
        --output text)
    
    if [[ -n "$sns_topic_arn" ]]; then
        print_success "SNS topic is created: $sns_topic_arn"
    fi
    
    print_success "Deployment verification completed"
}

# Function to display deployment summary
display_summary() {
    print_status "Deployment Summary"
    echo "=================="
    echo "Environment: $ENVIRONMENT"
    echo "AWS Region: $AWS_REGION"
    echo "Alert Email: $ALERT_EMAIL"
    echo "Warning Threshold: ${DISK_THRESHOLD_WARNING}%"
    echo "Critical Threshold: ${DISK_THRESHOLD_CRITICAL}%"
    echo "Emergency Threshold: ${DISK_THRESHOLD_EMERGENCY}%"
    echo "Monitoring Interval: ${MONITORING_INTERVAL} seconds"
    echo "Monitored Accounts: $MONITORED_ACCOUNTS"
    echo ""
    
    # Get CloudFormation outputs
    local stack_name="disk-monitoring-${ENVIRONMENT}"
    local dashboard_url=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='DashboardUrl'].OutputValue" \
        --output text)
    
    if [[ -n "$dashboard_url" ]]; then
        echo "CloudWatch Dashboard: $dashboard_url"
    fi
    
    print_success "AWS Cloud-Based Disk Monitoring Solution deployment completed successfully!"
}

# Main execution
main() {
    print_status "Starting AWS Cloud-Based Disk Monitoring Solution deployment..."
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -r|--region)
                AWS_REGION="$2"
                shift 2
                ;;
            -a|--accounts)
                MONITORED_ACCOUNTS="$2"
                shift 2
                ;;
            -m|--email)
                ALERT_EMAIL="$2"
                shift 2
                ;;
            -s|--slack)
                SLACK_WEBHOOK_URL="$2"
                shift 2
                ;;
            -p|--pagerduty)
                PAGERDUTY_API_KEY="$2"
                shift 2
                ;;
            -w|--warning)
                DISK_THRESHOLD_WARNING="$2"
                shift 2
                ;;
            -c|--critical)
                DISK_THRESHOLD_CRITICAL="$2"
                shift 2
                ;;
            -u|--emergency)
                DISK_THRESHOLD_EMERGENCY="$2"
                shift 2
                ;;
            -i|--interval)
                MONITORING_INTERVAL="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Check prerequisites
    check_prerequisites
    
    # Validate configuration
    validate_configuration
    
    # Deploy infrastructure
    if [[ "$DRY_RUN" != true ]]; then
        deploy_cloudformation_stack
        deploy_lambda_function
    fi
    
    # Run Ansible playbooks
    run_ansible_playbooks
    
    # Verify deployment
    if [[ "$DRY_RUN" != true ]]; then
        verify_deployment
    fi
    
    # Display summary
    display_summary
}

# Run main function
main "$@" 