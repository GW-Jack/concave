; ============================================================================
; Concave Analytics Formal Verification Suite (Z3 SMT-LIB2)
; ============================================================================
; Verifies bit-exact arithmetic safety, flag variant partitioning, trends
; bucket conservation, and live/bounded ReadSet interval soundness.
;
; Matches implementation:
;   - packages/analytics/Hash.roc      (overflow-free 31-bit modular hash)
;   - packages/analytics/Flags.roc     (cumulative-weight variant partitioning)
;   - packages/analytics/Insights.roc  (safe_add_i64, safe_mul_nonneg_i64, trends auto-widening)
;   - packages/analytics/Analytics.roc (live & bounded ReadSet bounds)
;
; Run with:
;   z3 specs/z3/analytics.smt2
;
; Expected output: every (check-sat) returns `unsat` (zero counterexamples).
; ============================================================================

(set-option :print-success false)

; ============================================================================
; PROOF 1: Bit-exact I64 Overflow Freedom & Range Bounds of Hash.roc
; ============================================================================
(echo "=== Proof 1: Hash.roc BV64 overflow freedom & exact output range ===")
(push)

(define-fun MOD () (_ BitVec 64) (_ bv2147483647 64))
(define-fun M1  () (_ BitVec 64) (_ bv48271 64))
(define-fun M2  () (_ BitVec 64) (_ bv16807 64))
(define-fun MAX_I64 () (_ BitVec 64) #x7fffffffffffffff)

(declare-const h (_ BitVec 64))
(declare-const b (_ BitVec 64))

; Preconditions: h in [0, 2147483647), b in [0, 255]
(assert (bvsge h (_ bv0 64)))
(assert (bvslt h MOD))
(assert (bvsge b (_ bv0 64)))
(assert (bvsle b (_ bv255 64)))

; Use 128-bit exact integers to prove zero 64-bit signed overflow!
(define-fun h128 () (_ BitVec 128) ((_ sign_extend 64) h))
(define-fun b128 () (_ BitVec 128) ((_ sign_extend 64) b))
(define-fun m1_128 () (_ BitVec 128) (_ bv48271 128))
(define-fun m2_128 () (_ BitVec 128) (_ bv16807 128))
(define-fun max64_128 () (_ BitVec 128) ((_ sign_extend 64) MAX_I64))

; 1a. Per-byte step: h * 48271 + b + 131 never overflows signed I64 and is >= 0
(echo "Proof 1a (per-byte step fits in [0, I64.max] without overflow):")
(push)
(define-fun step_exact () (_ BitVec 128)
  (bvadd (bvadd (bvmul h128 m1_128) b128) (_ bv131 128)))
(assert (or (bvslt step_exact (_ bv0 128)) (bvsgt step_exact max64_128)))
(check-sat)
(pop)

; 1b. Avalanche round 1: h * 48271 + 1234567 never overflows signed I64
(echo "Proof 1b (avalanche round 1 fits in [0, I64.max] without overflow):")
(push)
(define-fun av1_exact () (_ BitVec 128)
  (bvadd (bvmul h128 m1_128) (_ bv1234567 128)))
(assert (or (bvslt av1_exact (_ bv0 128)) (bvsgt av1_exact max64_128)))
(check-sat)
(pop)

; 1c. Avalanche round 2: h * 16807 + 9876543 never overflows signed I64
(echo "Proof 1c (avalanche round 2 fits in [0, I64.max] without overflow):")
(push)
(define-fun av2_exact () (_ BitVec 128)
  (bvadd (bvmul h128 m2_128) (_ bv9876543 128)))
(assert (or (bvslt av2_exact (_ bv0 128)) (bvsgt av2_exact max64_128)))
(check-sat)
(pop)

; 1d. Output buckets: bucket_bps in [0, 10000) and bucket_pct in [0, 100)
(echo "Proof 1d (bucket_bps in [0, 10000) and bucket_pct in [0, 100)):")
(push)
(define-fun bps () (_ BitVec 64) (bvsrem h (_ bv10000 64)))
(define-fun pct () (_ BitVec 64) (bvsdiv bps (_ bv100 64)))
(assert (or (bvslt bps (_ bv0 64)) (bvsge bps (_ bv10000 64))
            (bvslt pct (_ bv0 64)) (bvsge pct (_ bv100 64))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 2: Bit-exact I64 Overflow Freedom of safe_add_i64 & safe_mul_nonneg_i64
; ============================================================================
(echo "=== Proof 2: Insights.roc saturating I64 arithmetic ===")
(push)

(define-fun MAX64 () (_ BitVec 64) #x7fffffffffffffff)
(define-fun MAX64_128 () (_ BitVec 128) ((_ sign_extend 64) MAX64))

(declare-const a (_ BitVec 64))
(declare-const b (_ BitVec 64))

; 2a. safe_add_i64 for a >= 0, b >= 0 matches min(a + b, MAX64) in exact 128-bit arithmetic
(echo "Proof 2a (safe_add_i64 exact saturation for all non-negative I64 pairs):")
(push)
(assert (bvsge a (_ bv0 64)))
(assert (bvsge b (_ bv0 64)))
(define-fun safe_add () (_ BitVec 64)
  (ite (and (bvsgt b (_ bv0 64)) (bvsgt a (bvsub MAX64 b)))
       MAX64
       (bvadd a b)))
(define-fun exact_sum () (_ BitVec 128)
  (bvadd ((_ sign_extend 64) a) ((_ sign_extend 64) b)))
(define-fun expected () (_ BitVec 128)
  (ite (bvsgt exact_sum MAX64_128) MAX64_128 exact_sum))
(assert (not (= ((_ sign_extend 64) safe_add) expected)))
(check-sat)
(pop)

; 2b. safe_mul_nonneg_i64 matches min(a * b, MAX64) for all a >= 0, b >= 0 (exact Int arithmetic)
(echo "Proof 2b (safe_mul_nonneg_i64 exact saturation & overflow freedom for all non-negative I64 pairs):")
(push)
(declare-const ai Int)
(declare-const bi Int)
(define-fun MAX64_INT () Int 9223372036854775807)
(assert (and (>= ai 0) (<= ai MAX64_INT)))
(assert (and (>= bi 0) (<= bi MAX64_INT)))
(define-fun safe_mul_i () Int
  (ite (or (<= ai 0) (<= bi 0))
       0
       (ite (> ai (div MAX64_INT bi))
            MAX64_INT
            (* ai bi))))
(define-fun expected_mul_i () Int
  (ite (> (* ai bi) MAX64_INT) MAX64_INT (* ai bi)))
; Verify both exact value equality AND that when (* ai bi) is evaluated, (* ai bi) <= MAX64_INT
(assert (or (not (= safe_mul_i expected_mul_i))
            (and (> ai 0) (> bi 0) (<= ai (div MAX64_INT bi)) (> (* ai bi) MAX64_INT))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 3: Flags.roc Cumulative-Weight Variant Partitioning & Reachability
; ============================================================================
(echo "=== Proof 3: Flags.roc variant partitioning & reachability ===")
(push)

(declare-const w1 Int)
(declare-const w2 Int)
(declare-const w3 Int)
(declare-const h Int)

(assert (> w1 0))
(assert (> w2 0))
(assert (> w3 0))
(assert (<= (+ w1 w2 w3) 10000000))
(assert (>= h 0))
(assert (< h 2147483647))

(define-fun total () Int (+ w1 w2 w3))
(define-fun pick () Int (mod h total))

; Selection predicate for 3 variants:
;   v1: 0 <= pick < w1
;   v2: w1 <= pick < w1 + w2
;   v3: w1 + w2 <= pick < w1 + w2 + w3
(define-fun in_v1 ((p Int)) Bool (and (>= p 0) (< p w1)))
(define-fun in_v2 ((p Int)) Bool (and (>= p w1) (< p (+ w1 w2))))
(define-fun in_v3 ((p Int)) Bool (and (>= p (+ w1 w2)) (< p total)))

; 3a. Exhaustiveness & mutual exclusion: every hash lands in EXACTLY one variant
(echo "Proof 3a (every hash hits exactly one variant — total & disjoint):")
(push)
(assert (not (or (and (in_v1 pick) (not (in_v2 pick)) (not (in_v3 pick)))
                 (and (not (in_v1 pick)) (in_v2 pick) (not (in_v3 pick)))
                 (and (not (in_v1 pick)) (not (in_v2 pick)) (in_v3 pick)))))
(check-sat)
(pop)

; 3b. Reachability for ALL valid weights up to 10,000,000 (even when w1 > 10,000!)
(echo "Proof 3b (every variant is reachable in [0, 2147483647) for all valid weights):")
(push)
(define-fun h_v1 () Int 0)
(define-fun h_v2 () Int w1)
(define-fun h_v3 () Int (+ w1 w2))
(assert (not (and (< h_v1 2147483647) (in_v1 (mod h_v1 total))
                  (< h_v2 2147483647) (in_v2 (mod h_v2 total))
                  (< h_v3 2147483647) (in_v3 (mod h_v3 total)))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 4: Insights.roc Trends Auto-Widening & Bucket Conservation
; ============================================================================
(echo "=== Proof 4: Insights.roc Trends auto-widening & bucket conservation ===")
(push)

(declare-const from_ms Int)
(declare-const to_ms Int)
(declare-const req_bucket Int)
(declare-const ts Int)

(assert (>= from_ms 0))
(assert (>= to_ms from_ms))
(assert (> req_bucket 0))
(assert (and (>= ts from_ms) (<= ts to_ms)))

(define-fun span () Int (- to_ms from_ms))
(define-fun min_step () Int (+ (div span 500) 1))
(define-fun step () Int (ite (< req_bucket min_step) min_step req_bucket))

; Bucket index of ts: k = (ts - from_ms) div step
(define-fun k () Int (div (- ts from_ms) step))
(define-fun b_start () Int (+ from_ms (* k step)))
(define-fun b_end () Int (+ b_start step))

; 4a. Bucket index k is always in [0, 499] (so <= 500 buckets cover the ENTIRE [from_ms, to_ms]!)
(echo "Proof 4a (every ts in [from_ms, to_ms] maps to bucket index k in [0, 499]):")
(push)
(assert (or (< k 0) (>= k 500)))
(check-sat)
(pop)

; 4b. Uniqueness: ts lies in [b_start, b_end) for k and NOT in any other bucket j != k
(echo "Proof 4b (exact unique bucket membership => sum(buckets.count) == total_events):")
(push)
(declare-const j Int)
(assert (>= j 0))
(assert (< j 500))
(define-fun in_j () Bool (and (>= ts (+ from_ms (* j step)))
                              (< ts (+ from_ms (* (+ j 1) step)))))
(assert (not (= in_j (= j k))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 5: Analytics.roc ReadSet Interval Soundness (Bounded & Live Scans)
; ============================================================================
(echo "=== Proof 5: Analytics.roc ReadSet soundness (bounded & live scans) ===")
(push)

; Model composite key (event_id, ts, creation_time) under lexicographic order.
(declare-const ev1 Int)
(declare-const ev2 Int)
(declare-const from_ms Int)
(declare-const to_ms Int)
(declare-const ts Int)
(declare-const ct Int)

(define-fun lex_ge_2 ((eA Int) (tA Int) (eB Int) (tB Int)) Bool
  (or (> eA eB) (and (= eA eB) (>= tA tB))))

(define-fun lex_lt_2 ((eA Int) (tA Int) (eB Int) (tB Int)) Bool
  (or (< eA eB) (and (= eA eB) (< tA tB))))

; 5a. Bounded `events_by_event_time` scan: gte([ev1, from_ms]) && lt([ev1, to_ms + 1])
;     Recall keys have trailing `ct`: key = (ev2, ts, ct).
;     (ev2, ts, ct) >= (ev1, from_ms)  <=>  ev2 > ev1 or (ev2 == ev1 and ts >= from_ms)
;     (ev2, ts, ct) <  (ev1, to_ms+1)  <=>  ev2 < ev1 or (ev2 == ev1 and ts < to_ms + 1)
(echo "Proof 5a (bounded trends ReadSet matches iff ev2 == ev1 and from_ms <= ts <= to_ms):")
(push)
(assert (<= from_ms to_ms))
(define-fun in_bounded () Bool
  (and (lex_ge_2 ev2 ts ev1 from_ms)
       (lex_lt_2 ev2 ts ev1 (+ to_ms 1))))
(define-fun exact_match () Bool
  (and (= ev2 ev1) (>= ts from_ms) (<= ts to_ms)))
(assert (not (= in_bounded exact_match)))
(check-sat)
(pop)

; 5b. Live `events_by_event_time` scan (`to_ms <= 0`):
;     eq([ev1]) |> gte([ev1, from_ms])  =>  start = Included([ev1, from_ms]), end = Prefix([ev1])
;     Prefix([ev1]) upper bound matches iff ev2 <= ev1 (strictly < (ev1, 0xFF)).
(echo "Proof 5b (live trends ReadSet matches iff ev2 == ev1 and ts >= from_ms — surgical & reactive):")
(push)
(define-fun in_live () Bool
  (and (lex_ge_2 ev2 ts ev1 from_ms)
       (<= ev2 ev1)))
(define-fun live_match () Bool
  (and (= ev2 ev1) (>= ts from_ms)))
(assert (not (= in_live live_match)))
(check-sat)
(pop)

(pop)
