.PHONY: install build test test-one summary clean

install:
	forge install foundry-rs/forge-std --no-commit || true
	forge install OpenZeppelin/openzeppelin-contracts --no-commit || true

build:
	forge build

test:
	forge test -vv

test-one:
	@if [ -z "$(ID)" ]; then echo "usage: make test-one ID=F01-01"; exit 1; fi
	forge test --match-path "strategies/$(ID)-*/PoC.t.sol" -vvv

test-family:
	@if [ -z "$(F)" ]; then echo "usage: make test-family F=F01"; exit 1; fi
	forge test --match-path "strategies/$(F)-*/PoC.t.sol" -vv

summary:
	@cat strategies/_index.md 2>/dev/null || echo "Run Wave 3 first."
