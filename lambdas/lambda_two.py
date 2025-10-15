def handler(event, context):
    print("Lambda2: running")
    return {"lambda": "two", "status": "ok", "data": "Result from Lambda Two"}
