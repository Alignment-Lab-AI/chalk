.PHONY: testdeps
testdeps:
	rm -f chalk
	docker compose run --rm chalk-compile

.PHONY: test
test:
	docker compose run --rm --service-ports --use-aliases tests

.PHONY: chalkosx
chalkosx:
	rm -f chalk
	DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib con4m gen ./src/configs/chalk.c42spec --language=nim --output-file=./src/c4autoconf.nim
	nimble build
	mv chalk chalk-macos-arm64

.PHONY: chalkosxrelease
chalkosxrelease:
	rm -f chalk
	DYLD_LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib con4m gen ./src/configs/chalk.c42spec --language=nim --output-file=./src/c4autoconf.nim
	nimble build -d:release
	mv chalk chalk-macos-arm64-release

.PHONY: configdeps
configdeps:
	mkdir -p .config-tool-bin
	rm -f chalk
	docker compose run --rm chalk-compile sh -c 'nimble release'
	mv chalk .config-tool-bin/chalk-release
	docker compose run --rm chalk-compile sh -c 'nimble debug'
	mv chalk .config-tool-bin
	docker compose build chalk-config-compile

.PHONY: chalkconf
chalkconf:
	docker compose run --rm chalk-config-compile \
		sh -c "pyinstaller --onefile chalk_config/chalkconf.py --collect-all textual --collect-all rich && mv dist/chalkconf /config-bin/"

.PHONY: config
config:
	docker compose run --rm chalk-config-compile sh -c "python chalk_config/chalkconf.py"

.PHONY: configfmt
configfmt:
	docker compose run --rm chalk-config-compile sh -c "autoflake --remove-all-unused-imports -r chalk_config -i"
	docker compose run --rm chalk-config-compile sh -c "isort --profile \"black\" chalk_config"
	docker compose run --rm chalk-config-compile sh -c "black chalk_config"

.PHONY: configlint
configlint:
	docker compose run --rm chalk-config-compile sh -c "flake8 --extend-ignore=D chalk_config"
	docker compose run --rm chalk-config-compile sh -c "isort --profile \"black\" --check chalk_config"
	docker compose run --rm chalk-config-compile sh -c "black --check chalk_config"
	docker compose run --rm chalk-config-compile sh -c "mypy chalk_config"
