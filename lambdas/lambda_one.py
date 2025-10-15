def handler(event, context):
    print("Lambda1: running")
    return {"lambda": "one", "status": "ok", "data": "Result from Lambda One"}
