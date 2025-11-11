FROM python:3.13-slim

COPY . /app/
WORKDIR /app

RUN pip install --root-user-action=ignore -r requirements.txt

EXPOSE 8089
CMD ["sh", "-c", "locust -f main.py,executors $LOCUST_OPTIONS"]