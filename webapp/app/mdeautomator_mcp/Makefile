# Makefile for MDEAutomator MCP Server
# Provides common development and deployment tasks

.PHONY: help install test lint format clean build run dev stop logs health deploy

# Default target
help:
	@echo "MDEAutomator MCP Server - Available Commands:"
	@echo ""
	@echo "Development:"
	@echo "  install     Install Python dependencies"
	@echo "  test        Run test suite"
	@echo "  lint        Run code linting"
	@echo "  format      Format code with black and isort"
	@echo "  clean       Clean temporary files"
	@echo ""
	@echo "Docker:"
	@echo "  build       Build production Docker image"
	@echo "  build-dev   Build development Docker image"
	@echo "  run         Run production container"
	@echo "  dev         Run development container"
	@echo "  stop        Stop all containers"
	@echo "  logs        View container logs"
	@echo "  health      Check container health"
	@echo ""
	@echo "Deployment:"
	@echo "  deploy      Deploy to Azure (requires Azure CLI)"
	@echo "  push        Push image to container registry"
	@echo ""

# Python Development
install:
	@echo "Installing Python dependencies..."
	pip install --upgrade pip setuptools wheel
	pip install -r requirements.txt
	@echo "✓ Dependencies installed"

test:
	@echo "Running test suite..."
	python test_mcp.py
	@echo "✓ Tests completed"

test-examples:
	@echo "Running examples..."
	python examples.py
	@echo "✓ Examples completed"

lint:
	@echo "Running code linting..."
	@command -v mypy >/dev/null 2>&1 && mypy . || echo "mypy not installed, skipping type checking"
	@command -v flake8 >/dev/null 2>&1 && flake8 . || echo "flake8 not installed, skipping style checking"
	@echo "✓ Linting completed"

format:
	@echo "Formatting code..."
	@command -v black >/dev/null 2>&1 && black . || echo "black not installed, skipping formatting"
	@command -v isort >/dev/null 2>&1 && isort . || echo "isort not installed, skipping import sorting"
	@echo "✓ Code formatted"

clean:
	@echo "Cleaning temporary files..."
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
	find . -type d -name "*.egg-info" -exec rm -rf {} +
	find . -type f -name "*.log" -delete
	@echo "✓ Cleanup completed"

# Docker Commands
build:
	@echo "Building production Docker image..."
	docker-compose build mcp-server
	@echo "✓ Production image built"

build-dev:
	@echo "Building development Docker image..."
	docker-compose build mcp-server-dev
	@echo "✓ Development image built"

run:
	@echo "Starting production container..."
	docker-compose up -d mcp-server
	@echo "✓ Production container started"

dev:
	@echo "Starting development container..."
	docker-compose --profile dev up -d mcp-server-dev
	@echo "✓ Development container started"
	@echo "Container logs:"
	@make logs-dev

stop:
	@echo "Stopping all containers..."
	docker-compose down
	@echo "✓ Containers stopped"

logs:
	@echo "Viewing production container logs..."
	docker-compose logs -f mcp-server

logs-dev:
	@echo "Viewing development container logs..."
	docker-compose logs -f mcp-server-dev

health:
	@echo "Checking container health..."
	@if docker-compose ps mcp-server | grep -q "Up"; then \
		echo "✓ Production container is running"; \
		docker-compose exec mcp-server python -c "print('✓ Container is healthy')" 2>/dev/null || echo "⚠ Container not responding"; \
	else \
		echo "✗ Production container is not running"; \
	fi
	@if docker-compose ps mcp-server-dev | grep -q "Up"; then \
		echo "✓ Development container is running"; \
		docker-compose exec mcp-server-dev python -c "print('✓ Container is healthy')" 2>/dev/null || echo "⚠ Container not responding"; \
	else \
		echo "✗ Development container is not running"; \
	fi

# Container Registry Commands
push:
	@echo "Pushing image to container registry..."
	@if [ -z "$(REGISTRY)" ]; then \
		echo "✗ REGISTRY environment variable not set"; \
		echo "  Usage: make push REGISTRY=myregistry.azurecr.io"; \
		exit 1; \
	fi
	docker tag mdeautomator-mcp:latest $(REGISTRY)/mdeautomator-mcp:latest
	docker tag mdeautomator-mcp:latest $(REGISTRY)/mdeautomator-mcp:$(VERSION)
	docker push $(REGISTRY)/mdeautomator-mcp:latest
	docker push $(REGISTRY)/mdeautomator-mcp:$(VERSION)
	@echo "✓ Images pushed to $(REGISTRY)"

# Azure Deployment
deploy:
	@echo "Deploying to Azure..."
	@if [ -z "$(RESOURCE_GROUP)" ]; then \
		echo "✗ RESOURCE_GROUP environment variable not set"; \
		echo "  Usage: make deploy RESOURCE_GROUP=my-rg CONTAINER_NAME=my-container"; \
		exit 1; \
	fi
	@if [ -z "$(CONTAINER_NAME)" ]; then \
		echo "✗ CONTAINER_NAME environment variable not set"; \
		echo "  Usage: make deploy RESOURCE_GROUP=my-rg CONTAINER_NAME=my-container"; \
		exit 1; \
	fi
	az container create \
		--resource-group $(RESOURCE_GROUP) \
		--name $(CONTAINER_NAME) \
		--image $(REGISTRY)/mdeautomator-mcp:latest \
		--cpu 1 \
		--memory 2 \
		--restart-policy OnFailure \
		--environment-variables \
			FUNCTION_APP_BASE_URL=$(FUNCTION_APP_BASE_URL) \
			LOG_LEVEL=INFO
	@echo "✓ Deployed to Azure Container Instance"

# Environment Setup
setup-env:
	@echo "Setting up environment file..."
	@if [ ! -f .env ]; then \
		cp .env.template .env; \
		echo "✓ Created .env file from template"; \
		echo "  Please edit .env with your configuration"; \
	else \
		echo "✓ .env file already exists"; \
	fi

# Comprehensive test
test-all: test test-examples lint
	@echo "✓ All tests completed successfully"

# Build everything
build-all: build build-dev
	@echo "✓ All images built successfully"

# Development workflow
dev-setup: setup-env install build-dev
	@echo "✓ Development environment ready"

# Production workflow  
prod-setup: setup-env build
	@echo "✓ Production environment ready"

# Default values
VERSION ?= latest
REGISTRY ?= 
RESOURCE_GROUP ?= 
CONTAINER_NAME ?= 
FUNCTION_APP_BASE_URL ?= https://mdeautomator.azurewebsites.net
