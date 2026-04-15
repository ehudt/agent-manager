.PHONY: build clean test

build:
	go build -o bin/am-list-internal ./cmd/am-list-internal/
	go build -o bin/am-browse ./cmd/am-browse/

test:
	go test ./...

clean:
	rm -f bin/am-list-internal bin/am-browse
