def handler(event, context):
    print("Lambda3: running")
    return {"lambda": "three", "status": "ok", "data": "Result from Lambda Three"}
