.PHONY: build clean

build:
	go build -o bin/am-list-internal ./cmd/am-list-internal/

clean:
	rm -f bin/am-list-internal
