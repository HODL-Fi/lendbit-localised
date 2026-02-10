const fs = require("fs");
const path = require("path");

const filenames = [
    "OwnershipFacet",
    "ProtocolFacet",
    "PositionManagerFacet",
    "VaultManagerFacet",
    "PriceOracleFacet",
    "LiquidationFacet",
    "GettersFacet",
];

async function extractAbi() {
    const abis = [];
    for (const name of filenames) {
        const filePath = path.join("out", `${name}.sol`, `${name}.json`);
        const raw = await fs.promises.readFile(filePath, "utf8");
        const data = JSON.parse(raw);
        if (Array.isArray(data.abi)) {
            abis.push(...data.abi);
        }
    }
    return abis;
}

async function main() {
    try {
        const abis = await extractAbi();
        await fs.promises.writeFile("CombinedABI.json", JSON.stringify(abis, null, 4), "utf8");
        console.log("CombinedABI.json written.");
    } catch (err) {
        console.error("Error:", err.message);
        process.exit(1);
    }
}

main();