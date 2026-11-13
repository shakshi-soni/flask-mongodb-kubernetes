# Start from a small official Python image
FROM python:3.11-slim

# Set the working folder inside the container
WORKDIR /app

# Copy the requirements first so Docker can cache the install step
COPY requirements.txt .

# Install the Python packages
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY app.py .

# The Flask app listens on port 5000
EXPOSE 5000

# Start the app with Gunicorn
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]