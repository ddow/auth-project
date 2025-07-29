FROM public.ecr.aws/lambda/python:3.12

# Copy requirements file
COPY requirements.txt ${LAMBDA_TASK_ROOT}

# Install dependencies
RUN pip install -r requirements.txt --target "${LAMBDA_TASK_ROOT}"

# Copy function code and entrypoint
COPY main.py ${LAMBDA_TASK_ROOT}
COPY entrypoint.sh ${LAMBDA_TASK_ROOT}
RUN chmod +x ${LAMBDA_TASK_ROOT}/entrypoint.sh

# Set the CMD to use the entrypoint
CMD [ "./entrypoint.sh" ]