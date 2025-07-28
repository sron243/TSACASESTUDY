#!/usr/bin/env python3
"""
AWS Lambda Function for Disk Monitoring Data Collection and Aggregation
This function collects disk usage metrics from multiple AWS accounts and aggregates them
for centralized monitoring and alerting.
"""

import json
import boto3
import logging
import os
from datetime import datetime, timedelta
from typing import Dict, List, Any
import time

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
cloudwatch = boto3.client('cloudwatch')
ssm = boto3.client('ssm')
sts = boto3.client('sts')
sns = boto3.client('sns')

# Configuration
CONFIG = {
    'namespace': os.environ.get('MONITORING_NAMESPACE', 'DiskMonitoring'),
    'log_retention_days': int(os.environ.get('LOG_RETENTION_DAYS', '30')),
    'alert_threshold_warning': int(os.environ.get('ALERT_THRESHOLD_WARNING', '80')),
    'alert_threshold_critical': int(os.environ.get('ALERT_THRESHOLD_CRITICAL', '90')),
    'alert_threshold_emergency': int(os.environ.get('ALERT_THRESHOLD_EMERGENCY', '95')),
    'sns_topic_arn': os.environ.get('SNS_TOPIC_ARN'),
    'slack_webhook_url': os.environ.get('SLACK_WEBHOOK_URL'),
    'pagerduty_api_key': os.environ.get('PAGERDUTY_API_KEY'),
    'central_account_id': os.environ.get('CENTRAL_ACCOUNT_ID'),
    'cross_account_role_name': os.environ.get('CROSS_ACCOUNT_ROLE_NAME', 'DiskMonitoringRole')
}

class DiskMonitoringCollector:
    """Main class for collecting and aggregating disk monitoring data"""
    
    def __init__(self):
        self.current_account = sts.get_caller_identity()['Account']
        self.aggregated_data = {}
        self.alerts = []
        
    def get_aws_accounts(self) -> List[str]:
        """Get list of AWS accounts to monitor"""
        # In a real implementation, this would come from a database or parameter store
        # For this example, we'll use environment variables
        accounts = os.environ.get('MONITORED_ACCOUNTS', '').split(',')
        return [acc.strip() for acc in accounts if acc.strip()]
    
    def assume_role(self, account_id: str, role_name: str) -> boto3.Session:
        """Assume cross-account role"""
        try:
            role_arn = f"arn:aws:iam::{account_id}:role/{role_name}"
            assumed_role = sts.assume_role(
                RoleArn=role_arn,
                RoleSessionName=f"DiskMonitoring-{int(time.time())}",
                ExternalId="disk-monitoring-solution"
            )
            
            return boto3.Session(
                aws_access_key_id=assumed_role['Credentials']['AccessKeyId'],
                aws_secret_access_key=assumed_role['Credentials']['SecretAccessKey'],
                aws_session_token=assumed_role['Credentials']['SessionToken']
            )
        except Exception as e:
            logger.error(f"Failed to assume role in account {account_id}: {str(e)}")
            return None
    
    def collect_metrics_from_account(self, account_id: str, session: boto3.Session) -> Dict[str, Any]:
        """Collect disk metrics from a specific AWS account"""
        try:
            cloudwatch_client = session.client('cloudwatch')
            
            # Get disk usage metrics for the last hour
            end_time = datetime.utcnow()
            start_time = end_time - timedelta(hours=1)
            
            response = cloudwatch_client.get_metric_statistics(
                Namespace=CONFIG['namespace'],
                MetricName='disk_used_percent',
                Dimensions=[
                    {'Name': 'InstanceId', 'Value': '*'},
                    {'Name': 'Filesystem', 'Value': '/'}
                ],
                StartTime=start_time,
                EndTime=end_time,
                Period=300,  # 5-minute intervals
                Statistics=['Average', 'Maximum', 'Minimum']
            )
            
            account_data = {
                'account_id': account_id,
                'timestamp': datetime.utcnow().isoformat(),
                'metrics': response['Datapoints'],
                'instance_count': len(set(dp['Dimensions'][0]['Value'] for dp in response['Datapoints']))
            }
            
            logger.info(f"Collected {len(response['Datapoints'])} metrics from account {account_id}")
            return account_data
            
        except Exception as e:
            logger.error(f"Failed to collect metrics from account {account_id}: {str(e)}")
            return {
                'account_id': account_id,
                'timestamp': datetime.utcnow().isoformat(),
                'error': str(e),
                'metrics': [],
                'instance_count': 0
            }
    
    def analyze_metrics(self, account_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Analyze metrics and generate alerts"""
        alerts = []
        
        for datapoint in account_data.get('metrics', []):
            avg_usage = datapoint.get('Average', 0)
            instance_id = next((dim['Value'] for dim in datapoint['Dimensions'] if dim['Name'] == 'InstanceId'), 'Unknown')
            
            if avg_usage >= CONFIG['alert_threshold_emergency']:
                alert_level = 'EMERGENCY'
                priority = 'high'
            elif avg_usage >= CONFIG['alert_threshold_critical']:
                alert_level = 'CRITICAL'
                priority = 'high'
            elif avg_usage >= CONFIG['alert_threshold_warning']:
                alert_level = 'WARNING'
                priority = 'medium'
            else:
                continue
            
            alert = {
                'account_id': account_data['account_id'],
                'instance_id': instance_id,
                'alert_level': alert_level,
                'priority': priority,
                'disk_usage': avg_usage,
                'timestamp': datapoint['Timestamp'].isoformat(),
                'threshold': CONFIG[f'alert_threshold_{alert_level.lower()}']
            }
            
            alerts.append(alert)
        
        return alerts
    
    def send_alert(self, alert: Dict[str, Any]) -> bool:
        """Send alert through configured channels"""
        try:
            message = self.format_alert_message(alert)
            
            # Send SNS notification
            if CONFIG['sns_topic_arn']:
                sns.publish(
                    TopicArn=CONFIG['sns_topic_arn'],
                    Subject=f"Disk Usage {alert['alert_level']} - {alert['instance_id']}",
                    Message=message
                )
            
            # Send Slack notification
            if CONFIG['slack_webhook_url']:
                self.send_slack_alert(alert, message)
            
            # Send PagerDuty alert
            if CONFIG['pagerduty_api_key'] and alert['priority'] == 'high':
                self.send_pagerduty_alert(alert, message)
            
            logger.info(f"Alert sent for {alert['instance_id']} in account {alert['account_id']}")
            return True
            
        except Exception as e:
            logger.error(f"Failed to send alert: {str(e)}")
            return False
    
    def format_alert_message(self, alert: Dict[str, Any]) -> str:
        """Format alert message for different channels"""
        return f"""
Disk Usage Alert - {alert['alert_level']}

Account: {alert['account_id']}
Instance: {alert['instance_id']}
Usage: {alert['disk_usage']:.1f}%
Threshold: {alert['threshold']}%
Time: {alert['timestamp']}

This alert was generated by the AWS Cloud-Based Disk Monitoring Solution.
        """.strip()
    
    def send_slack_alert(self, alert: Dict[str, Any], message: str):
        """Send alert to Slack"""
        import urllib.request
        import urllib.parse
        
        slack_data = {
            'text': message,
            'username': 'Disk Monitoring Bot',
            'icon_emoji': ':warning:' if alert['alert_level'] in ['WARNING', 'CRITICAL'] else ':rotating_light:'
        }
        
        data = urllib.parse.urlencode({'payload': json.dumps(slack_data)}).encode('utf-8')
        req = urllib.request.Request(CONFIG['slack_webhook_url'], data=data)
        urllib.request.urlopen(req)
    
    def send_pagerduty_alert(self, alert: Dict[str, Any], message: str):
        """Send alert to PagerDuty"""
        import urllib.request
        import urllib.parse
        
        pagerduty_data = {
            'routing_key': CONFIG['pagerduty_api_key'],
            'event_action': 'trigger',
            'payload': {
                'summary': f"Disk Usage {alert['alert_level']} - {alert['instance_id']}",
                'severity': 'critical' if alert['alert_level'] == 'EMERGENCY' else 'warning',
                'source': f"aws-{alert['account_id']}",
                'custom_details': message
            }
        }
        
        data = json.dumps(pagerduty_data).encode('utf-8')
        req = urllib.request.Request(
            'https://events.pagerduty.com/v2/enqueue',
            data=data,
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(req)
    
    def store_aggregated_data(self, aggregated_data: Dict[str, Any]):
        """Store aggregated data in CloudWatch"""
        try:
            # Store summary metrics
            cloudwatch.put_metric_data(
                Namespace=f"{CONFIG['namespace']}/Aggregated",
                MetricData=[
                    {
                        'MetricName': 'TotalInstancesMonitored',
                        'Value': sum(acc['instance_count'] for acc in aggregated_data.values()),
                        'Unit': 'Count',
                        'Timestamp': datetime.utcnow()
                    },
                    {
                        'MetricName': 'TotalAlertsGenerated',
                        'Value': len(self.alerts),
                        'Unit': 'Count',
                        'Timestamp': datetime.utcnow()
                    },
                    {
                        'MetricName': 'AccountsMonitored',
                        'Value': len(aggregated_data),
                        'Unit': 'Count',
                        'Timestamp': datetime.utcnow()
                    }
                ]
            )
            
            logger.info(f"Stored aggregated metrics: {len(aggregated_data)} accounts, {len(self.alerts)} alerts")
            
        except Exception as e:
            logger.error(f"Failed to store aggregated data: {str(e)}")
    
    def run(self) -> Dict[str, Any]:
        """Main execution method"""
        logger.info("Starting disk monitoring data collection")
        
        # Get list of accounts to monitor
        accounts = self.get_aws_accounts()
        logger.info(f"Monitoring {len(accounts)} AWS accounts")
        
        # Collect data from each account
        for account_id in accounts:
            if account_id == self.current_account:
                # Use current session for central account
                session = boto3.Session()
            else:
                # Assume cross-account role
                session = self.assume_role(account_id, CONFIG['cross_account_role_name'])
                if not session:
                    continue
            
            # Collect metrics
            account_data = self.collect_metrics_from_account(account_id, session)
            self.aggregated_data[account_id] = account_data
            
            # Analyze metrics and generate alerts
            alerts = self.analyze_metrics(account_data)
            self.alerts.extend(alerts)
            
            # Send alerts
            for alert in alerts:
                self.send_alert(alert)
        
        # Store aggregated data
        self.store_aggregated_data(self.aggregated_data)
        
        # Return summary
        return {
            'accounts_monitored': len(self.aggregated_data),
            'total_instances': sum(acc['instance_count'] for acc in self.aggregated_data.values()),
            'total_alerts': len(self.alerts),
            'timestamp': datetime.utcnow().isoformat(),
            'status': 'success'
        }

def lambda_handler(event, context):
    """AWS Lambda handler function"""
    try:
        collector = DiskMonitoringCollector()
        result = collector.run()
        
        logger.info(f"Disk monitoring collection completed: {result}")
        return {
            'statusCode': 200,
            'body': json.dumps(result)
        }
        
    except Exception as e:
        logger.error(f"Lambda execution failed: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

if __name__ == "__main__":
    # For local testing
    collector = DiskMonitoringCollector()
    result = collector.run()
    print(json.dumps(result, indent=2)) 