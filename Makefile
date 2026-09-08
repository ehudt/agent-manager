.PHONY: build clean test check

build:
	go build -o bin/am-list-internal ./cmd/am-list-internal/
	go build -o bin/am-browse ./cmd/am-browse/
	go build -o bin/am-core ./cmd/am-core/
	go build -o bin/am-review ./cmd/am-review/

test:
	go test ./...

check:
	go vet ./... && go test ./...

clean:
	rm -f bin/am-list-internal bin/am-browse bin/am-core bin/am-review
