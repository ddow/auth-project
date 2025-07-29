FROM public.ecr.aws/lambda/python:3.12

# Copy requirements file
COPY requirements.txt ${LAMBDA_TASK_ROOT}

# Install dependencies
RUN pip install -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

# Copy function code
COPY main.py ${LAMBDA_TASK_ROOT}

# Set the CMD to your handler
CMD [ "main.handler" ]