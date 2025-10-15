import json
import boto3
import os

def handler(event, context):
    sns = boto3.client("sns")
    topic_arn = os.environ["SNS_TOPIC_ARN"]

    message = {
        "subject": "Lambda Execution Results",
        "results": event
    }

    sns.publish(
        TopicArn=topic_arn,
        Subject="Terraform DevOps Parallel Lambda Execution Results",
        Message=json.dumps(message, indent=2)
    )

    return {"status": "SNS message sent", "topic": topic_arn}
