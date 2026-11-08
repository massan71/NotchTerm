.PHONY: build run install clean

build:
	./build.sh

run: build
	-pkill -x NotchTerm
	open build/NotchTerm.app

install: build
	-pkill -x NotchTerm
	rm -rf /Applications/NotchTerm.app
	cp -R build/NotchTerm.app /Applications/
	open /Applications/NotchTerm.app

clean:
	rm -rf build .build
