const { ethers } = require("ethers");

// All custom errors from Error.sol, ReceiverTemplate.sol, and LendbitSpoke.sol
const ERROR_SIGNATURES = [
  // Error.sol
  "ADDRESS_ZERO()",
  "ADDRESS_EXISTS(address)",
  "NO_POSITION_ID(address)",
  "NO_ACCESS_TO_POSITION_ID(address)",
  "POSITION_ID_MISMATCH(uint256,uint256)",
  "ONLY_SECURITY_COUNCIL()",
  "SUBSCRIPTION_ID_NOT_SET()",
  "TOKEN_NOT_SUPPORTED(address)",
  "TOKEN_ALREADY_SUPPORTED(address,address)",
  "TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(address)",
  "TOKEN_NOT_SUPPORTED_AS_COLLATERAL(address)",
  "REQUEST_SIGNER_NOT_SET()",
  "REQUEST_INVALID_SIGNATURE(address)",
  "REQUEST_REPAY_NONCE_USED(address,uint256)",
  "REQUEST_REPAY_TARGET_CHAIN_MISMATCH(uint256,uint256)",
  "REQUEST_REPAY_CONTRACT_MISMATCH(address,address)",
  "REQUEST_BORROW_SIGNER_NOT_SET()",
  "REQUEST_BORROW_INVALID_SIGNATURE(address)",
  "REQUEST_BORROW_NONCE_USED(address,uint256)",
  "REQUEST_BORROW_TARGET_CHAIN_MISMATCH(uint256,uint256)",
  "REQUEST_BORROW_CONTRACT_MISMATCH(address,address)",
  "AMOUNT_ZERO()",
  "BAD_RATE()",
  "AMOUNT_MISMATCH(uint256,uint256)",
  "TRANSFER_FAILED()",
  "INSUFFICIENT_ALLOWANCE()",
  "INSUFFICIENT_BALANCE()",
  "INSUFFICIENT_COLLATERAL()",
  "HEALTH_FACTOR_TOO_LOW(uint256)",
  "NOT_LIQUIDATABLE()",
  "NO_ACTIVE_BORROW_FOR_TOKEN(uint256,address)",
  "NO_COLLATERAL_FOR_TOKEN(uint256,address)",
  "NOT_LOAN_OWNER(uint256)",
  "ADDRESS_NOT_WHITELISTED(address)",
  "LTV_BELOW_TEN_PERCENT()",
  "TOKEN_OVERUTILIZATION()",
  "NO_OUTSTANDING_DEBT(uint256,address)",
  "INACTIVE_LOAN()",
  "UNKNOWN_ACTION(string)",
  "EMPTY_STRING()",
  "CURRENCY_ALREADY_SUPPORTED(string)",
  "CURRENCY_NOT_SUPPORTED(string)",
  "STALE_PRICE_FEED(address)",
  "INVALID_PRICE_FEED(address)",
  "ZERO_PRICE_DATA()",
  "YIELD_ALLOCATION_TOO_HIGH(uint16)",
  "YIELD_NOT_ENABLED(address)",
  "YIELD_TOKEN_PAUSED(address)",
  "YIELD_NOTHING_TO_CLAIM(uint256,address)",
  "YIELD_LIQUIDITY_DEFICIT(address,uint256)",
  "OnlyRouterCanFulfill()",
  "UnexpectedRequestID(bytes32)",
  // ReceiverTemplate / CRE errors
  "InvalidForwarderAddress()",
  "InvalidSender(address,address)",
  "InvalidAuthor(address,address)",
  "InvalidWorkflowName(bytes10,bytes10)",
  "InvalidWorkflowId(bytes32,bytes32)",
  "WorkflowNameRequiresAuthorValidation()",
  // OZ
  "OwnableUnauthorizedAccount(address)",
  "OwnableInvalidOwner(address)",
];

// Build selector → (name, param types) lookup
const errorMap = new Map();
for (const sig of ERROR_SIGNATURES) {
  const iface = new ethers.utils.Interface([`function ${sig}`]); // trick: parse as function to get selector
  const selector = ethers.utils.id(sig).slice(0, 10);
  errorMap.set(selector, sig);
}

function decode(hexData) {
  let data = hexData.trim();
  if (!data.startsWith("0x")) data = "0x" + data;

  if (data.length < 10) {
    console.log("Data too short to contain an error selector.");
    return;
  }

  const selector = data.slice(0, 10).toLowerCase();
  const sig = errorMap.get(selector);

  if (!sig) {
    console.log(`Unknown error selector: ${selector}`);
    console.log("Raw data:", data);
    // Print selector table for reference
    console.log("\nKnown selectors:");
    for (const [sel, s] of errorMap) {
      console.log(`  ${sel} => ${s}`);
    }
    return;
  }

  console.log(`Error: ${sig}`);

  // Extract param types from signature
  const paramStr = sig.slice(sig.indexOf("(") + 1, sig.lastIndexOf(")"));
  if (!paramStr) {
    console.log("(no parameters)");
    return;
  }

  const paramTypes = paramStr.split(",").map((t) => t.trim());
  const paramsData = "0x" + data.slice(10);

  try {
    const abiCoder = new ethers.utils.AbiCoder();
    const decoded = abiCoder.decode(paramTypes, paramsData);
    console.log("\nDecoded parameters:");
    for (let i = 0; i < paramTypes.length; i++) {
      const val = decoded[i];
      const display =
        typeof val === "object" && val._isBigNumber
          ? val.toString()
          : val.toString();
      console.log(`  [${i}] ${paramTypes[i]}: ${display}`);
    }
  } catch (e) {
    console.log("Failed to decode parameters:", e.message);
    console.log("Raw params data:", paramsData);
  }
}

// Usage: node scripts/decodeError.js <hex-encoded-revert-data>
const input = process.argv[2];
if (!input) {
  console.log("Usage: node scripts/decodeError.js <revert-data-hex>");
  console.log('Example: node scripts/decodeError.js 0x...');
  process.exit(1);
}

decode(input);
