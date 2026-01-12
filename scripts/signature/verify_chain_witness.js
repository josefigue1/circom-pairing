const fs = require('fs');

// Read witness files (tienen todos los signals, no solo públicos)
const w1 = JSON.parse(fs.readFileSync('build/part1/witness.json', 'utf8'));
const w2 = JSON.parse(fs.readFileSync('build/part2/witness.json', 'utf8'));
const w3 = JSON.parse(fs.readFileSync('build/part3/witness.json', 'utf8'));

// En witness.json:
// - Índice 0: siempre 1
// - Luego vienen los public signals en orden
// - Luego los private signals

// Part1: public [ pubkey, signature, hash ], output Hm
// En witness: [1, Hm(28), pubkey(14), signature(28), hash(28), ...private...]
const hm1 = w1.slice(1, 29); // Hm es el primer output

// Part2: public [ pubkey, signature, Hm ], output miller_out  
// En witness: [1, miller_out(84), pubkey(14), signature(28), Hm(28), ...private...]
const miller2 = w2.slice(1, 85); // miller_out es el primer output
const hm2 = w2.slice(127, 155); // Hm viene después de miller_out(84 pubkey(14) + signature(28) = 126, pero índice 0 es 1, así que 127

// Part3: public [ miller_out ]
// En witness: [1, miller_out(84), ...private...]
const miller3 = w3.slice(1, 85);

console.log('🔗 Chain Verification (using witness.json):');
console.log('');

// Verificar Hm
let hmMatch = true;
let firstMismatch = -1;
for (let i = 0; i < 28; i++) {
    if (hm1[i] !== hm2[i]) {
        hmMatch = false;
        if (firstMismatch === -1) firstMismatch = i;
    }
}

if (hmMatch) {
    console.log('  Hm (Part1 → Part2): ✅ VALID');
} else {
    console.log('  Hm (Part1 → Part2): ❌ INVALID');
    console.log(`    First mismatch at index ${firstMismatch}`);
    console.log(`    Part1[${firstMismatch}]: ${hm1[firstMismatch]}`);
    console.log(`    Part2[${127 + firstMismatch}]: ${hm2[firstMismatch]}`);
}

// Verificar miller_out
let millerMatch = true;
firstMismatch = -1;
for (let i = 0; i < 84; i++) {
    if (miller2[i] !== miller3[i]) {
        millerMatch = false;
        if (firstMismatch === -1) h = i;
    }
}

if (millerMatch) {
    console.log('  miller_out (Part2 → Part3): ✅ VALID');
} else {
    console.log('  miller_out (Part2 → Part3): ❌ INVALID');
    console.log(`    First mismatch at index ${firstMismatch}`);
}

console.log('');

if (hmMatch && millerMatch) {
    console.log('✅ All chains are valid! Circuit split is working correctly.');
    process.exit(0);
} else {
    console.log('❌ Chain mismatch detected!');
    console.log('');
    console.log('Debug info:');
    console.log(`  Part1 witness length: ${w1.length}`);
    console.log(`  Part2 witness length: ${w2.length}`);
    console.log(`  Part3 witness length: ${w3.length}`);
    console.log(`  Part1 Hm (first 3): ${hm1.slice(0, 3).join(', ')}`);
    console.log(`  Part2 Hm (first 3): ${hm2.slice(0, 3).join(', ')}`);
    process.exit(1);
}
