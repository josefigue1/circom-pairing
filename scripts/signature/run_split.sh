#!/bin/bash

# =============================================================================
# BLS Signature Split Circuit - Build and Proof Generation
# =============================================================================
# This script compiles, generates witnesses, trusted setup, and proofs for
# the 3 split BLS signature verification circuits.
#
# The split reduces RAM usage by running 3 smaller circuits sequentially:
#   Part1: Checks + MapToG2 (~6M constraints) -> outputs Hm
#   Part2: MillerLoop (~8M constraints) -> outputs miller_out  
#   Part3: FinalExponentiate (~5M constraints) -> verifies == 1
#
# Usage: ./run_split.sh [--compile-only] [--witness-only] [--full]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_BASE="$SCRIPT_DIR/build"

# Powers of Tau file - adjust path as needed
PHASE1="$SCRIPT_DIR/../../circuits/pot25_final.ptau"
# Alternative path if the above doesn't exist
PHASE1_ALT="$SCRIPT_DIR/../../../../../powers_of_tau/powersOfTau28_hez_final_27.ptau"

# Node path (use system node by default, or patched node if available)
if [ -f "$SCRIPT_DIR/../../../../../node/out/Release/node" ]; then
    NODE_PATH="$SCRIPT_DIR/../../../../../node/out/Release/node"
    NODE_OPTS="--trace-gc --trace-gc-ignore-scavenger --max-old-space-size=2048000 --initial-old-space-size=2048000 --no-global-gc-scheduling --no-incremental-marking --max-semi-space-size=1024 --initial-heap-size=2048000 --expose-gc"
else
    NODE_PATH="node"
    NODE_OPTS="--max-old-space-size=8192"
fi

# Rapidsnark prover (optional, falls back to snarkjs)
PROVER_PATH="$SCRIPT_DIR/../../../../../rapidsnark/build/prover"

# Input file
INPUT_FILE="$SCRIPT_DIR/input_signature.json"

# Circuit names
CIRCUITS=("signature_part1" "signature_part2" "signature_part3")

# Verifier output directory
VERIFIER_DIR="$SCRIPT_DIR/verifiers"

# =============================================================================
# Helper Functions
# =============================================================================

log_step() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

log_substep() {
    echo "---- $1"
}

check_phase1() {
    if [ -f "$PHASE1" ]; then
        echo "Found Phase 1 ptau file: $PHASE1"
    elif [ -f "$PHASE1_ALT" ]; then
        PHASE1="$PHASE1_ALT"
        echo "Found Phase 1 ptau file: $PHASE1"
    else
        echo "ERROR: No Phase 1 ptau file found."
        echo "Please download from: https://github.com/iden3/snarkjs#7-prepare-phase-2"
        echo "Expected locations:"
        echo "  - $PHASE1"
        echo "  - $PHASE1_ALT"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$BUILD_BASE/part1"
    mkdir -p "$BUILD_BASE/part2"
    mkdir -p "$BUILD_BASE/part3"
    mkdir -p "$VERIFIER_DIR"
    mkdir -p "$SCRIPT_DIR/logs"
}

# =============================================================================
# Compilation
# =============================================================================

compile_circuit() {
    local part_num=$1
    local circuit_name="signature_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    if [ -f "$build_dir/${circuit_name}.r1cs" ]; then
        log_substep "Circuit $circuit_name already compiled, skipping..."
        return 0
    fi
    
    log_substep "Compiling $circuit_name.circom..."
    local start=$(date +%s)
    
    circom "$SCRIPT_DIR/${circuit_name}.circom" \
        --O1 \
        --r1cs \
        --wasm \
        --sym \
        --output "$build_dir"
    
    local end=$(date +%s)
    echo "Compiled in $((end - start))s"
    
    # Show constraint count
    if command -v snarkjs &> /dev/null; then
        echo "Constraint info:"
        snarkjs r1cs info "$build_dir/${circuit_name}.r1cs" 2>/dev/null || true
    fi
}

compile_all() {
    log_step "PHASE: Compiling all circuits"
    for i in 1 2 3; do
        compile_circuit $i
    done
}

# =============================================================================
# Witness Generation with Chaining
# =============================================================================

generate_witness_part1() {
    local build_dir="$BUILD_BASE/part1"
    local circuit_name="signature_part1"
    
    log_substep "Generating witness for Part1..."
    local start=$(date +%s)
    
    # Copy input file
    cp "$INPUT_FILE" "$build_dir/input.json"
    
    # Generate witness using WASM
    $NODE_PATH "$build_dir/${circuit_name}_js/generate_witness.js" \
        "$build_dir/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir/input.json" \
        "$build_dir/witness.wtns"
    
    # Export to JSON to extract public signals
    snarkjs wtns export json "$build_dir/witness.wtns" "$build_dir/witness.json"
    
    local end=$(date +%s)
    echo "Part1 witness generated in $((end - start))s"
}

generate_witness_part2() {
    local build_dir_1="$BUILD_BASE/part1"
    local build_dir_2="$BUILD_BASE/part2"
    local circuit_name="signature_part2"
    
    log_substep "Extracting Hm from Part1 and generating witness for Part2..."
    local start=$(date +%s)
    
    # Use Node.js to extract Hm and create Part2 input
    $NODE_PATH -e "
    const fs = require('fs');
    
    // Read Part1 witness
    const witness1 = JSON.parse(fs.readFileSync('$build_dir_1/witness.json', 'utf8'));
    
    // Read original input for pubkey and signature
    const originalInput = JSON.parse(fs.readFileSync('$INPUT_FILE', 'utf8'));
    
    // Part1 public signals: [Hm (28), pubkey (14), signature (28), hash (28)] = 98 total
    // Hm is at indices 1-28 in witness (index 0 is always 1)
    const hmFlat = witness1.slice(1, 29);
    
    // Reshape Hm to [2][2][7]
    const Hm = [];
    let idx = 0;
    for (let i = 0; i < 2; i++) {
        Hm[i] = [];
        for (let j = 0; j < 2; j++) {
            Hm[i][j] = hmFlat.slice(idx, idx + 7);
            idx += 7;
        }
    }
    
    // Create Part2 input
    const inputPart2 = {
        pubkey: originalInput.pubkey,
        signature: originalInput.signature,
        Hm: Hm
    };
    
    fs.writeFileSync('$build_dir_2/input.json', JSON.stringify(inputPart2, null, 2));
    console.log('Created Part2 input with Hm extracted from Part1');
    "
    
    # Generate witness using WASM
    $NODE_PATH "$build_dir_2/${circuit_name}_js/generate_witness.js" \
        "$build_dir_2/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_2/input.json" \
        "$build_dir_2/witness.wtns"
    
    # Export to JSON
    snarkjs wtns export json "$build_dir_2/witness.wtns" "$build_dir_2/witness.json"
    
    local end=$(date +%s)
    echo "Part2 witness generated in $((end - start))s"
}

generate_witness_part3() {
    local build_dir_2="$BUILD_BASE/part2"
    local build_dir_3="$BUILD_BASE/part3"
    local circuit_name="signature_part3"
    
    log_substep "Extracting miller_out from Part2 and generating witness for Part3..."
    local start=$(date +%s)
    
    # Use Node.js to extract miller_out and create Part3 input
    $NODE_PATH -e "
    const fs = require('fs');
    
    // Read Part2 witness
    const witness2 = JSON.parse(fs.readFileSync('$build_dir_2/witness.json', 'utf8'));
    
    // Part2 public signals: [miller_out (84), pubkey (14), signature (28), Hm (28)] = 154 total
    // miller_out is at indices 1-84 in witness
    const millerFlat = witness2.slice(1, 85);
    
    // Reshape miller_out to [6][2][7]
    const miller_out = [];
    let idx = 0;
    for (let i = 0; i < 6; i++) {
        miller_out[i] = [];
        for (let j = 0; j < 2; j++) {
            miller_out[i][j] = millerFlat.slice(idx, idx + 7);
            idx += 7;
        }
    }
    
    // Create Part3 input
    const inputPart3 = {
        miller_out: miller_out
    };
    
    fs.writeFileSync('$build_dir_3/input.json', JSON.stringify(inputPart3, null, 2));
    console.log('Created Part3 input with miller_out extracted from Part2');
    "
    
    # Generate witness using WASM
    $NODE_PATH "$build_dir_3/${circuit_name}_js/generate_witness.js" \
        "$build_dir_3/${circuit_name}_js/${circuit_name}.wasm" \
        "$build_dir_3/input.json" \
        "$build_dir_3/witness.wtns"
    
    # Export to JSON
    snarkjs wtns export json "$build_dir_3/witness.wtns" "$build_dir_3/witness.json"
    
    local end=$(date +%s)
    echo "Part3 witness generated in $((end - start))s"
}

generate_all_witnesses() {
    log_step "PHASE: Generating witnesses (with chaining)"
    generate_witness_part1
    generate_witness_part2
    generate_witness_part3
    echo ""
    echo "All witnesses generated successfully!"
}

# =============================================================================
# Trusted Setup (zkey generation)
# =============================================================================

generate_zkey() {
    local part_num=$1
    local circuit_name="signature_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    if [ -f "$build_dir/${circuit_name}.zkey" ]; then
        log_substep "zkey for $circuit_name already exists, skipping..."
        return 0
    fi
    
    log_substep "Generating zkey for $circuit_name..."
    local start=$(date +%s)
    
    # Phase 2 setup
    $NODE_PATH $NODE_OPTS \
        $(which snarkjs) zkey new \
        "$build_dir/${circuit_name}.r1cs" \
        "$PHASE1" \
        "$build_dir/${circuit_name}_0.zkey"
    
    # Contribute to ceremony
    $NODE_PATH $(which snarkjs) zkey contribute \
        "$build_dir/${circuit_name}_0.zkey" \
        "$build_dir/${circuit_name}.zkey" \
        -n="First contribution" \
        -e="random entropy $(date +%s)"
    
    # Remove intermediate zkey
    rm -f "$build_dir/${circuit_name}_0.zkey"
    
    # Export verification key
    $NODE_PATH $(which snarkjs) zkey export verificationkey \
        "$build_dir/${circuit_name}.zkey" \
        "$build_dir/vkey.json"
    
    local end=$(date +%s)
    echo "zkey generated in $((end - start))s"
}

generate_all_zkeys() {
    log_step "PHASE: Generating trusted setup (zkeys)"
    check_phase1
    for i in 1 2 3; do
        generate_zkey $i
    done
}

# =============================================================================
# Proof Generation
# =============================================================================

generate_proof() {
    local part_num=$1
    local circuit_name="signature_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    log_substep "Generating proof for $circuit_name..."
    local start=$(date +%s)
    
    if [ -f "$PROVER_PATH" ]; then
        # Use rapidsnark if available (faster)
        $PROVER_PATH \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json"
    else
        # Fall back to snarkjs
        $NODE_PATH $NODE_OPTS \
            $(which snarkjs) groth16 prove \
            "$build_dir/${circuit_name}.zkey" \
            "$build_dir/witness.wtns" \
            "$build_dir/proof.json" \
            "$build_dir/public.json"
    fi
    
    local end=$(date +%s)
    echo "Proof generated in $((end - start))s"
}

verify_proof() {
    local part_num=$1
    local circuit_name="signature_part${part_num}"
    local build_dir="$BUILD_BASE/part${part_num}"
    
    log_substep "Verifying proof for $circuit_name..."
    
    $NODE_PATH $(which snarkjs) groth16 verify \
        "$build_dir/vkey.json" \
        "$build_dir/public.json" \
        "$build_dir/proof.json"
}

generate_all_proofs() {
    log_step "PHASE: Generating proofs"
    for i in 1 2 3; do
        generate_proof $i
    done
    
    log_step "PHASE: Verifying proofs"
    for i in 1 2 3; do
        verify_proof $i
    done
}

# =============================================================================
# Export Solidity Verifiers
# =============================================================================

export_verifiers() {
    log_step "PHASE: Exporting Solidity verifiers"
    
    for i in 1 2 3; do
        local circuit_name="signature_part${i}"
        local build_dir="$BUILD_BASE/part${i}"
        local verifier_name="VerifierPart${i}.sol"
        
        if [ -f "$build_dir/${circuit_name}.zkey" ]; then
            log_substep "Exporting verifier for Part${i}..."
            $NODE_PATH $(which snarkjs) zkey export solidityverifier \
                "$build_dir/${circuit_name}.zkey" \
                "$VERIFIER_DIR/$verifier_name"
            echo "Created $VERIFIER_DIR/$verifier_name"
        else
            echo "WARNING: zkey for Part${i} not found, skipping verifier export"
        fi
    done
    
    # Generate calldata for each proof
    log_substep "Generating calldata..."
    for i in 1 2 3; do
        local build_dir="$BUILD_BASE/part${i}"
        if [ -f "$build_dir/proof.json" ] && [ -f "$build_dir/public.json" ]; then
            $NODE_PATH $(which snarkjs) zkey export soliditycalldata \
                "$build_dir/public.json" \
                "$build_dir/proof.json" \
                > "$build_dir/calldata.txt"
            echo "Created $build_dir/calldata.txt"
        fi
    done
}

# =============================================================================
# Chain Verification
# =============================================================================

verify_chain() {
    log_step "PHASE: Verifying chain consistency"
    
    $NODE_PATH -e "
    const fs = require('fs');
    
    // Read all public signals
    const public1 = JSON.parse(fs.readFileSync('$BUILD_BASE/part1/public.json', 'utf8'));
    const public2 = JSON.parse(fs.readFileSync('$BUILD_BASE/part2/public.json', 'utf8'));
    const public3 = JSON.parse(fs.readFileSync('$BUILD_BASE/part3/public.json', 'utf8'));
    
    // Part1 outputs Hm at positions 0-27
    const hm_from_part1 = public1.slice(0, 28);
    
    // Part2 has Hm as public input at positions 84+14+28 = 126 to 153
    // Actually: miller_out(84) + pubkey(14) + signature(28) + Hm(28)
    const hm_in_part2 = public2.slice(126, 154);
    
    // Part2 outputs miller_out at positions 0-83
    const miller_from_part2 = public2.slice(0, 84);
    
    // Part3 has miller_out as public input at positions 0-83
    const miller_in_part3 = public3.slice(0, 84);
    
    // Verify Hm chain
    let hmMatch = true;
    for (let i = 0; i < 28; i++) {
        if (hm_from_part1[i] !== hm_in_part2[i]) {
            hmMatch = false;
            console.log('Hm mismatch at index ' + i);
            break;
        }
    }
    console.log('Hm chain (Part1 -> Part2): ' + (hmMatch ? '✓ VALID' : '✗ INVALID'));
    
    // Verify miller_out chain
    let millerMatch = true;
    for (let i = 0; i < 84; i++) {
        if (miller_from_part2[i] !== miller_in_part3[i]) {
            millerMatch = false;
            console.log('miller_out mismatch at index ' + i);
            break;
        }
    }
    console.log('miller_out chain (Part2 -> Part3): ' + (millerMatch ? '✓ VALID' : '✗ INVALID'));
    
    if (hmMatch && millerMatch) {
        console.log('');
        console.log('✓ All chain verifications passed!');
        process.exit(0);
    } else {
        console.log('');
        console.log('✗ Chain verification failed!');
        process.exit(1);
    }
    "
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================="
    echo "BLS Signature Split Circuit - Build & Prove"
    echo "=============================================="
    echo "Script directory: $SCRIPT_DIR"
    echo "Build directory: $BUILD_BASE"
    echo "Node: $NODE_PATH"
    echo ""
    
    local mode="${1:-full}"
    
    ensure_dirs
    
    case "$mode" in
        --compile-only)
            compile_all
            ;;
        --witness-only)
            generate_all_witnesses
            ;;
        --zkey-only)
            generate_all_zkeys
            ;;
        --proof-only)
            generate_all_proofs
            ;;
        --verify-chain)
            verify_chain
            ;;
        --export-verifiers)
            export_verifiers
            ;;
        --full|*)
            compile_all
            generate_all_witnesses
            generate_all_zkeys
            generate_all_proofs
            export_verifiers
            verify_chain
            ;;
    esac
    
    echo ""
    echo "=============================================="
    echo "Done!"
    echo "=============================================="
}

# Run with logging
mkdir -p "$SCRIPT_DIR/logs"
main "$@" 2>&1 | tee "$SCRIPT_DIR/logs/run_split_$(date '+%Y-%m-%d-%H-%M').log"
