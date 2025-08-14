FROM public.ecr.aws/lambda/python:3.12

# Copy requirements and install into Lambda task root
COPY requirements.txt ${LAMBDA_TASK_ROOT}
RUN pip install --no-cache-dir -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

# Copy function code (main.py is your FastAPI + Mangum entry)
COPY main.py ${LAMBDA_TASK_ROOT}

# Lambda looks for this handler
CMD ["main.handler"]
