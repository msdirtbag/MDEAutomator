# Use the official Python image from Docker Hub
FROM python:3.11-slim-bullseye

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

# Set work directory
WORKDIR /app

# Install dependencies
COPY requirements.txt ./
RUN apt-get update && apt-get upgrade -y && \
	pip install --upgrade pip && \
	pip install -r requirements.txt && \
	apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy project files
COPY . .

# Expose the port Flask is running on
EXPOSE 5000
EXPOSE 80

# Set environment variable for Flask
ENV FLASK_APP=run.py

# Run the application
CMD ["python", "run.py"]
