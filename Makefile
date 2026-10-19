.PHONY: all build release test run app fast-app clean install

SWIFTPM_FLAGS = --scratch-path /tmp/freetypist-build --disable-sandbox --cache-path /tmp/swiftpm-cache --config-path /tmp/swiftpm-config --security-path /tmp/swiftpm-security -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache

all: build

build:
	CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift build -j 4 $(SWIFTPM_FLAGS)

release:
	CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift build -c release -j 4 $(SWIFTPM_FLAGS)

test:
	CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift test -j 4 $(SWIFTPM_FLAGS)

app:
	chmod +x Scripts/build_app.sh
	./Scripts/build_app.sh

fast-app:
	chmod +x Scripts/build_app.sh
	./Scripts/build_app.sh --debug

run: app
	open dist/FreeTypist.app

install: app
	cp -R dist/FreeTypist.app /Applications/
	@echo "Installed FreeTypist.app to /Applications/"

clean:
	swift package clean
	rm -rf .build /tmp/freetypist-build dist
