.PHONY: build up down logs restart test

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

restart: down up

test:
	docker compose run --rm kiosk python -c "from main import app; print('App imported OK')"
