# Static Analysis

## Static Analysis

forge build: OK

slither: available (slither-fresh.json — 146 detectors: 8 Medium, 8 Low, 130 Informational)

## STATIC_FINDINGS

### Medium-impact (slither)
- [incorrect-equality] TokenVault._accrueInterest() (contracts/TokenVault.sol#317-329) uses a dangerous strict equality: 	- timeElapsed == 0 (contracts/TokenVault.sol#319) 
- [incorrect-equality] TokenVault.withdraw(uint256,address,address) (contracts/TokenVault.sol#166-204) uses a dangerous strict equality: 	- shares == 0 (contracts/TokenVault.sol#181) 
- [incorrect-equality] TokenVault.deposit(uint256,address) (contracts/TokenVault.sol#132-157) uses a dangerous strict equality: 	- shares == 0 (contracts/TokenVault.sol#147) 
- [uninitialized-local] PriceOracleFacet.sendRequest(uint64,string[]).req (contracts/facets/PriceOracleFacet.sol#67) is a local variable never initialized 
- [unused-return] PriceOracleFacet.getTokenValueInUSD(address,uint256) (contracts/facets/PriceOracleFacet.sol#19-22) ignores return value by s._getTokenValueInUSD(_token,_amount) (contracts/facets/PriceOracleFacet.sol#21) 
- [unused-return] VaultManagerFacet.getTokenVaultDetails(address) (contracts/facets/VaultManagerFacet.sol#85-90) ignores return value by s._getTokenVaultDetails(_token) (contracts/facets/VaultManagerFacet.sol#89) 
- [unused-return] PriceOracleFacet.getPriceData(address) (contracts/facets/PriceOracleFacet.sol#14-17) ignores return value by s._getPriceData(_token) (contracts/facets/PriceOracleFacet.sol#16) 
- [unused-return] GettersFacet.getLoanDetails(uint256) (contracts/facets/GettersFacet.sol#113-131) ignores return value by s._getLoanDetails(_loanId) (contracts/facets/GettersFacet.sol#130) 

### Low-impact (slither)
- [events-maths] TokenVault.setInterestRate(uint16) (contracts/TokenVault.sol#272-276) should emit an event for:  	- interestRate = rate (contracts/TokenVault.sol#275)  
- [missing-zero-check] TokenVault.constructor(address,string,string,address,uint16)._diamond (contracts/TokenVault.sol#95) lacks a zero-check on : 		- diamond = _diamond (contracts/TokenVault.sol#101) 
- [timestamp] TokenVault.deposit(uint256,address) (contracts/TokenVault.sol#132-157) uses timestamp for comparisons 	Dangerous comparisons: 	- shares == 0 (contracts/TokenVault.sol#147) 
- [timestamp] TokenVault.burnFor(address,uint256) (contracts/TokenVault.sol#267-270) uses timestamp for comparisons 	Dangerous comparisons: 	- balanceOf(owner) < shares (contracts/TokenVault.sol#268) 
- [timestamp] TokenVault.repay(uint256) (contracts/TokenVault.sol#222-246) uses timestamp for comparisons 	Dangerous comparisons: 	- amount >= totalBorrows (contracts/TokenVault.sol#227) 	- amount > 0 (contracts/To
- [timestamp] TokenVault._accrueInterest() (contracts/TokenVault.sol#317-329) uses timestamp for comparisons 	Dangerous comparisons: 	- timeElapsed == 0 (contracts/TokenVault.sol#319) 	- interest > 0 (contracts/Tok
- [timestamp] TokenVault.updateBadDebt(uint256) (contracts/TokenVault.sol#278-315) uses timestamp for comparisons 	Dangerous comparisons: 	- amount > _totalBorrowedWithInterest (contracts/TokenVault.sol#285) 	- _re
- [timestamp] TokenVault.withdraw(uint256,address,address) (contracts/TokenVault.sol#166-204) uses timestamp for comparisons 	Dangerous comparisons: 	- shares == 0 (contracts/TokenVault.sol#181) 	- balanceOf(owner)

### Informational check histogram (slither)
-  127 naming-convention
-    2 unindexed-event-address
-    1 assembly
