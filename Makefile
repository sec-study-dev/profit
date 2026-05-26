.PHONY: install build test test-one summary clean

install:
	forge install foundry-rs/forge-std --no-commit || true
	forge install OpenZeppelin/openzeppelin-contracts --no-commit || true

build:
	forge build

test:
	forge test --match-path "strategies/**" -vv

test-one:
	@if [ -z "$(ID)" ]; then echo "usage: make test-one ID=F01-01"; exit 1; fi
	forge test --match-path "strategies/$(ID)-*/PoC.t.sol" -vvv

summary:
	@cat strategies/_index.md 2>/dev/null || echo "Run Wave 3 first."
