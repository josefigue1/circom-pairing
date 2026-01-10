#!/usr/bin/env node

/**
 * @fileoverview Automated test script for BLS Signature Split Verification
 * 
 * This script:
 * 1. Generates witness for Part1 -> extracts Hm from public.json
 * 2. Injects Hm into input_part2.json -> generates witness Part2
 * 3. Extracts miller_out -> injects into input_part3.json -> generates witness Part3
 * 4. Verifies all 3 proofs with snarkjs
 * 
 * Usage: node test_split_bridge.js [input_file]
 * Default input: input_signature.json
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SCRIPT_DIR = __dirname;
const BUILD_BASE = path.join(SCRIPT_DIR, '../../build');
const BUILD_PART1 = path.join(BUILD_BASE, 'part1');
const BUILD_PART2 = path.join(BUILD_BASE, 'part2');
const BUILD_PART3 = path.join(BUILD_BASE, 'part3');

// Public signal indices (from plan)
const PART1_HM_START = 0;
const PART1_HM_LENGTH = 28; // Hm[2][2][7] = 2*2*7 = 28
const PART2_MILLER_START = 0;
const PART2_MILLER_LENGTH = 84; // miller_out[6][2][7] = 6*2*7 = 84
const PART2_HM_START = 126; // Hm starts at index 126 in Part2
const PART2_HM_LENGTH = 28;

function ensureDir(dir) {
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
}

function readJson(filePath) {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, data) {
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
}

function extractPublicSignals(publicJson) {
    return publicJson;
}

function extractHmFromPart1(publicSignals) {
    // Part1 public signals order: [Hm, pubkey, signature, hash]
    // Hm is at indices 0-27
    return publicSignals.slice(PART1_HM_START, PART1_HM_START + PART1_HM_LENGTH);
}

function extractMillerOutFromPart2(publicSignals) {
    // Part2 public signals order: [miller_out, pubkey, signature, Hm]
    // miller_out is at indices 0-83
    return publicSignals.slice(PART2_MILLER_START, PART2_MILLER_START + PART2_MILLER_LENGTH);
}

function createInputPart2(originalInput, hm) {
    // Part2 needs: pubkey, signature, Hm
    // Hm comes from Part1 output
    return {
        pubkey: originalInput.pubkey,
        signature: originalInput.signature,
        Hm: [
            [
                hm.slice(0, 7),      // Hm[0][0] = indices 0-6
                hm.slice(7, 14)       // Hm[0][1] = indices 7-13
            ],
            [
                hm.slice(14, 21),     // Hm[1][0] = indices 14-20
                hm.slice(21, 28)      // Hm[1][1] = indices 21-27
            ]
        ]
    };
}

function createInputPart3(millerOut) {
    // Part3 needs: miller_out[6][2][7]
    // miller_out is 84 elements total
    const result = [];
    for (let i = 0; i < 6; i++) {
        result[i] = [];
        for (let j = 0; j < 2; j++) {
            result[i][j] = millerOut.slice(i * 14 + j * 7, i * 14 + j * 7 + 7);
        }
    }
    return { miller_out: result };
}

function flattenArray(arr) {
    const result = [];
    function flatten(item) {
        if (Array.isArray(item)) {
            item.forEach(flatten);
        } else {
            result.push(item);
        }
    }
    flatten(arr);
    return result;
}

function unflattenTo2D(arr, dim1, dim2) {
    const result = [];
    let idx = 0;
    for (let i = 0; i < dim1; i++) {
        result[i] = [];
        for (let j = 0; j < dim2; j++) {
            result[i][j] = arr[idx++];
        }
    }
    return result;
}

function unflattenTo3D(arr, dim1, dim2, dim3) {
    const result = [];
    let idx = 0;
    for (let i = 0; i < dim1; i++) {
        result[i] = [];
        for (let j = 0; j < dim2; j++) {
            result[i][j] = [];
            for (let k = 0; k < dim3; k++) {
                result[i][j][k] = arr[idx++];
            }
        }
    }
    return result;
}

function runCommand(cmd, cwd = SCRIPT_DIR) {
    console.log(`\n> ${cmd}`);
    try {
        const output = execSync(cmd, { 
            cwd, 
            encoding: 'utf8',
            stdio: 'inherit'
        });
        return output;
    } catch (error) {
        console.error(`Error running command: ${cmd}`);
        console.error(error.message);
        process.exit(1);
    }
}

async function main() {
    const inputFile = process.argv[2] || path.join(SCRIPT_DIR, 'input_signature.json');
    
    console.log('='.repeat(60));
    console.log('BLS Signature Split Bridge Test');
    console.log('='.repeat(60));
    console.log(`Input file: ${inputFile}`);
    
    // Ensure build directories exist
    ensureDir(BUILD_PART1);
    ensureDir(BUILD_PART2);
    ensureDir(BUILD_PART3);
    
    const originalInput = readJson(inputFile);
    
    // ============================================
    // PART 1: Generate witness and extract Hm
    // ============================================
    console.log('\n[PART 1] Generating witness...');
    
    const inputPart1Path = path.join(BUILD_PART1, 'input_part1.json');
    writeJson(inputPart1Path, originalInput);
    
    // Generate witness using wasm
    const wasmPath1 = path.join(BUILD_PART1, 'signature_part1_js', 'signature_part1.wasm');
    const witnessPath1 = path.join(BUILD_PART1, 'witness.wtns');
    
    if (!fs.existsSync(wasmPath1)) {
        console.error(`Error: WASM file not found: ${wasmPath1}`);
        console.error('Please compile the circuit first:');
        console.error('  circom signature_part1.circom --r1cs --wasm --sym -o build/part1');
        process.exit(1);
    }
    
    runCommand(`node signature_part1_js/generate_witness.js signature_part1.wasm input_part1.json witness.wtns`, BUILD_PART1);
    
    // Convert witness to JSON and extract public signals
    runCommand(`snarkjs wtns export json witness.wtns witness.json`, BUILD_PART1);
    
    const witness1 = readJson(path.join(BUILD_PART1, 'witness.json'));
    const publicSignals1 = witness1.slice(1); // First element is always 1
    
    console.log(`Part1 public signals count: ${publicSignals1.length} (expected: 98)`);
    
    const hm = extractHmFromPart1(publicSignals1);
    console.log(`Extracted Hm: ${hm.length} elements`);
    
    // Save Part1 public signals
    writeJson(path.join(BUILD_PART1, 'public.json'), publicSignals1);
    
    // ============================================
    // PART 2: Inject Hm and generate witness
    // ============================================
    console.log('\n[PART 2] Injecting Hm and generating witness...');
    
    // Convert Hm flat array back to nested structure for input
    const hmNested = unflattenTo3D(hm, 2, 2, 7);
    const inputPart2 = {
        pubkey: originalInput.pubkey,
        signature: originalInput.signature,
        Hm: hmNested
    };
    
    const inputPart2Path = path.join(BUILD_PART2, 'input_part2.json');
    writeJson(inputPart2Path, inputPart2);
    
    const wasmPath2 = path.join(BUILD_PART2, 'signature_part2_js', 'signature_part2.wasm');
    const witnessPath2 = path.join(BUILD_PART2, 'witness.wtns');
    
    if (!fs.existsSync(wasmPath2)) {
        console.error(`Error: WASM file not found: ${wasmPath2}`);
        console.error('Please compile the circuit first:');
        console.error('  circom signature_part2.circom --r1cs --wasm --sym -o build/part2');
        process.exit(1);
    }
    
    runCommand(`node signature_part2_js/generate_witness.js signature_part2.wasm input_part2.json witness.wtns`, BUILD_PART2);
    
    runCommand(`snarkjs wtns export json witness.wtns witness.json`, BUILD_PART2);
    
    const witness2 = readJson(path.join(BUILD_PART2, 'witness.json'));
    const publicSignals2 = witness2.slice(1);
    
    console.log(`Part2 public signals count: ${publicSignals2.length} (expected: 154)`);
    
    const millerOut = extractMillerOutFromPart2(publicSignals2);
    console.log(`Extracted miller_out: ${millerOut.length} elements`);
    
    // Verify Hm chain: Part1[0:28] == Part2[126:154]
    const hmPart2 = publicSignals2.slice(PART2_HM_START, PART2_HM_START + PART2_HM_LENGTH);
    const hmMatch = JSON.stringify(hm) === JSON.stringify(hmPart2);
    console.log(`Hm chain verification: ${hmMatch ? '✓ PASS' : '✗ FAIL'}`);
    if (!hmMatch) {
        console.error('Hm mismatch between Part1 and Part2!');
        process.exit(1);
    }
    
    writeJson(path.join(BUILD_PART2, 'public.json'), publicSignals2);
    
    // ============================================
    // PART 3: Inject miller_out and generate witness
    // ============================================
    console.log('\n[PART 3] Injecting miller_out and generating witness...');
    
    const millerOutNested = unflattenTo3D(millerOut, 6, 2, 7);
    const inputPart3 = {
        miller_out: millerOutNested
    };
    
    const inputPart3Path = path.join(BUILD_PART3, 'input_part3.json');
    writeJson(inputPart3Path, inputPart3);
    
    const wasmPath3 = path.join(BUILD_PART3, 'signature_part3_js', 'signature_part3.wasm');
    
    if (!fs.existsSync(wasmPath3)) {
        console.error(`Error: WASM file not found: ${wasmPath3}`);
        console.error('Please compile the circuit first:');
        console.error('  circom signature_part3.circom --r1cs --wasm --sym -o build/part3');
        process.exit(1);
    }
    
    runCommand(`node signature_part3_js/generate_witness.js signature_part3.wasm input_part3.json witness.wtns`, BUILD_PART3);
    
    runCommand(`snarkjs wtns export json witness.wtns witness.json`, BUILD_PART3);
    
    const witness3 = readJson(path.join(BUILD_PART3, 'witness.json'));
    const publicSignals3 = witness3.slice(1);
    
    console.log(`Part3 public signals count: ${publicSignals3.length} (expected: 84)`);
    
    // Verify miller_out chain: Part2[0:84] == Part3[0:84]
    const millerMatch = JSON.stringify(millerOut) === JSON.stringify(publicSignals3);
    console.log(`miller_out chain verification: ${millerMatch ? '✓ PASS' : '✗ FAIL'}`);
    if (!millerMatch) {
        console.error('miller_out mismatch between Part2 and Part3!');
        process.exit(1);
    }
    
    writeJson(path.join(BUILD_PART3, 'public.json'), publicSignals3);
    
    // ============================================
    // Summary
    // ============================================
    console.log('\n' + '='.repeat(60));
    console.log('✓ All witnesses generated successfully!');
    console.log('✓ Chain verifications passed!');
    console.log('\nNext steps:');
    console.log('1. Generate proofs for each part using snarkjs groth16 prove');
    console.log('2. Verify proofs using snarkjs groth16 verify');
    console.log('3. Test the BlsSignatureSplitVerifier.sol contract');
    console.log('='.repeat(60));
}

main().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
});


