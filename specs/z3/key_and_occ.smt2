; ============================================================================
; Concave Formal Verification Suite (Z3 SMT-LIB2)
; ============================================================================
; Verifies bit-exact correctness of Concave's order-preserving key codecs,
; KeyBound / ReadSet-WriteSet interval soundness, and OCC serializability.
;
; Matches implementation:
;   - zig/core/key.zig      (encodeValue for Int64 & Float64)
;   - zig/core/readset.zig  (KeyBound, IndexRangeRead.containsKey, ReadSet.intersects)
;   - zig/core/wal_store.zig (commitTx OCC validation & pre/post-image WriteSet)
;
; Run with:
;   /opt/homebrew/bin/z3 specs/z3/key_and_occ.smt2
;
; Expected output: every (check-sat) returns `unsat` (no counterexample exists).
; ============================================================================

(set-option :print-success false)

; ============================================================================
; PROOF 1: Bit-exact Int64 Order-Preserving Key Codec
; Matches zig/core/key.zig lines 118-125:
;   const raw: u64 = @bitCast(i);
;   const ordered = raw ^ (@as(u64, 1) << 63);
;   std.mem.writeInt(u64, &buf, ordered, .big);
; ============================================================================
(echo "=== Proof 1: Int64 Key Codec (order & injectivity over all 2^64 x 2^64 pairs) ===")
(push)
(define-fun enc_i64 ((x (_ BitVec 64))) (_ BitVec 64)
  (bvxor x #x8000000000000000))

(declare-const a (_ BitVec 64))
(declare-const b (_ BitVec 64))

; 1a. Strict signed order <=> strict unsigned (big-endian lexicographic) order
(echo "Proof 1a (bvslt a b <=> bvult (enc_i64 a) (enc_i64 b)):")
(push)
(assert (not (= (bvslt a b) (bvult (enc_i64 a) (enc_i64 b)))))
(check-sat)
(pop)

; 1b. Equality / injectivity
(echo "Proof 1b (a = b <=> enc_i64 a = enc_i64 b):")
(push)
(assert (not (= (= a b) (= (enc_i64 a) (enc_i64 b)))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 2: Bit-exact IEEE-754 Float64 Order-Preserving Key Codec
; Matches zig/core/key.zig lines 126-138:
;   if (std.math.isNan(f)) return error.InvalidKey;
;   const canonical: f64 = if (f == 0.0) 0.0 else f;
;   const bits: u64 = @bitCast(canonical);
;   const ordered = if ((bits & (@as(u64, 1) << 63)) != 0)
;       ~bits
;   else
;       bits ^ (@as(u64, 1) << 63);
;   std.mem.writeInt(u64, &buf, ordered, .big);
; ============================================================================
(echo "=== Proof 2: IEEE-754 Float64 Key Codec (all non-NaN pairs incl. subnormals, +-0.0, +-inf) ===")
(push)

; Bit-exact IEEE-754 binary64 interpretation of any 64-bit word
(define-fun bv_to_fp64 ((bits (_ BitVec 64))) (_ FloatingPoint 11 53)
  (fp ((_ extract 63 63) bits)
      ((_ extract 62 52) bits)
      ((_ extract 51 0)  bits)))

; Canonicalize -0.0 to +0.0, then apply Zig bit-flip formula
(define-fun enc_f64_bits ((bits (_ BitVec 64))) (_ BitVec 64)
  (let ((cb (ite (fp.isZero (bv_to_fp64 bits)) #x0000000000000000 bits)))
    (ite (not (= (bvand cb #x8000000000000000) #x0000000000000000))
         (bvnot cb)
         (bvxor cb #x8000000000000000))))

; Quantify over ALL 64-bit IEEE-754 patterns (surjective onto all Float64 values)
(declare-const bx (_ BitVec 64))
(declare-const by (_ BitVec 64))
(define-fun fx () (_ FloatingPoint 11 53) (bv_to_fp64 bx))
(define-fun fy () (_ FloatingPoint 11 53) (bv_to_fp64 by))

; Domain: all non-NaN Float64 values (NaN is rejected by encodeValue with InvalidKey)
(assert (not (fp.isNaN fx)))
(assert (not (fp.isNaN fy)))

; 2a. Strict IEEE-754 order <=> strict unsigned big-endian lexicographic order
(echo "Proof 2a (fp.lt x y <=> bvult (enc x) (enc y)):")
(push)
(assert (not (= (fp.lt fx fy) (bvult (enc_f64_bits bx) (enc_f64_bits by)))))
(check-sat)
(pop)

; 2b. IEEE-754 numeric equality (incl. -0.0 == +0.0) <=> encoded key equality
(echo "Proof 2b (fp.eq x y <=> enc x = enc y):")
(push)
(assert (not (= (fp.eq fx fy) (= (enc_f64_bits bx) (enc_f64_bits by)))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 3: KeyBound Interval & ReadSet ∩ WriteSet Soundness
; Matches zig/core/readset.zig lines 31-81 (KeyBound & IndexRangeRead.containsKey)
; and zig/core/wal_store.zig (recording both pre-image k_old and post-image k_new).
; ============================================================================
(echo "=== Proof 3: KeyBound Interval & ReadSet-WriteSet Soundness ===")
(push)

(declare-datatypes ((KeyBound 0))
  (((Unbounded)
    (Included (bound_inc (_ BitVec 64)))
    (Excluded (bound_exc (_ BitVec 64))))))

(define-fun above_start ((start KeyBound) (k (_ BitVec 64))) Bool
  (match start
    ((Unbounded true)
     ((Included lo) (bvuge k lo))
     ((Excluded lo) (bvugt k lo)))))

(define-fun below_end ((end KeyBound) (k (_ BitVec 64))) Bool
  (match end
    ((Unbounded true)
     ((Included hi) (bvule k hi))
     ((Excluded hi) (bvult k hi)))))

(define-fun contains_key ((start KeyBound) (end KeyBound) (k (_ BitVec 64))) Bool
  (and (above_start start k) (below_end end k)))

(declare-const sb KeyBound)
(declare-const eb KeyBound)
(declare-const k_old (_ BitVec 64))
(declare-const k_new (_ BitVec 64))

; 3a. Membership-change soundness:
;     If a document enters or leaves [start, end] between k_old and k_new,
;     then contains(k_old) \/ contains(k_new) MUST hold (so WriteSet intersects ReadSet).
(echo "Proof 3a (membership change => contains(k_old) \/ contains(k_new)):")
(push)
(assert (not (=> (distinct (contains_key sb eb k_old) (contains_key sb eb k_new))
                 (or (contains_key sb eb k_old) (contains_key sb eb k_new)))))
(check-sat)
(pop)

; 3b. Zero false negatives for full range visibility:
;     If WriteSet {k_old, k_new} does NOT intersect [start, end], then the document
;     is outside [start, end] both before AND after the mutation (neither visible
;     before, nor visible after, nor entering, nor leaving).
(echo "Proof 3b (~(contains(k_old) \/ contains(k_new)) => ~contains(k_old) /\ ~contains(k_new)):")
(push)
(assert (not (=> (not (or (contains_key sb eb k_old) (contains_key sb eb k_new)))
                 (and (not (contains_key sb eb k_old)) (not (contains_key sb eb k_new))))))
(check-sat)
(pop)

; 3c. Boundary precision: Excluded(x) strictly excludes x while Included(x) includes x
;     whenever the opposite bound is satisfied.
(echo "Proof 3c (Included/Excluded boundary precision):")
(push)
(declare-const bnd (_ BitVec 64))
(assert (not (and (not (contains_key (Excluded bnd) eb bnd))
                  (not (contains_key sb (Excluded bnd) bnd))
                  (=> (below_end eb bnd) (contains_key (Included bnd) eb bnd))
                  (=> (above_start sb bnd) (contains_key sb (Included bnd) bnd)))))
(check-sat)
(pop)

(pop)

; ============================================================================
; PROOF 4: OCC 2-Transaction Serializability
; Matches zig/core/wal_store.zig commitTx lines 204-212:
;   For every committed tx T_other with commit_ts_other > snapshot_ts:
;     if ReadSet.intersects(WriteSet_other) => return Conflict (Abort).
;
; Models two concurrent read-modify-write transactions T1, T2 over a database
; of documents (DocId -> Value) and secondary index keys (DocId -> Key64),
; where each tx has:
;   - snapshot_ts, commit_ts (with snapshot_ts < commit_ts and ts1 != ts2)
;   - ReadSet: a point doc read (with presence flag) + an index range scan [start, end]
;   - WriteSet: a written doc + BOTH pre-image and post-image index keys
; ============================================================================
(echo "=== Proof 4: OCC 2-Transaction Serializability ===")
(push)

(declare-datatypes ((KeyBound 0))
  (((Unbounded)
    (Included (bound_inc (_ BitVec 64)))
    (Excluded (bound_exc (_ BitVec 64))))))

(define-fun above_start ((start KeyBound) (k (_ BitVec 64))) Bool
  (match start
    ((Unbounded true)
     ((Included lo) (bvuge k lo))
     ((Excluded lo) (bvugt k lo)))))

(define-fun below_end ((end KeyBound) (k (_ BitVec 64))) Bool
  (match end
    ((Unbounded true)
     ((Included hi) (bvule k hi))
     ((Excluded hi) (bvult k hi)))))

(define-fun contains_key ((start KeyBound) (end KeyBound) (k (_ BitVec 64))) Bool
  (and (above_start start k) (below_end end k)))

; ReadSet intersects WriteSet (matching zig/core/readset.zig:204-222
; and zig/core/wal_store.zig pre-image + post-image index key recording):
;   - On insert:  has_old_k=false, has_new_k=true
;   - On update:  has_old_k=true,  has_new_k=true
;   - On delete:  has_old_k=true,  has_new_k=false
(define-fun rs_intersects_ws
  ((has_dr Bool) (r_doc (_ BitVec 16))
   (has_rr Bool) (r_start KeyBound) (r_end KeyBound)
   (has_w  Bool) (w_doc (_ BitVec 16))
   (w_has_old_k Bool) (w_k_old (_ BitVec 64))
   (w_has_new_k Bool) (w_k_new (_ BitVec 64))) Bool
  (and has_w
       (or (and has_dr (= r_doc w_doc))
           (and has_rr (or (and w_has_old_k (contains_key r_start r_end w_k_old))
                           (and w_has_new_k (contains_key r_start r_end w_k_new)))))))

; OCC validation predicate for T against T_other
(define-fun occ_valid
  ((snap Int) (ts_other Int)
   (has_dr Bool) (r_doc (_ BitVec 16))
   (has_rr Bool) (r_start KeyBound) (r_end KeyBound)
   (has_w_other Bool) (w_doc_other (_ BitVec 16))
   (w_has_old_other Bool) (w_k_old_other (_ BitVec 64))
   (w_has_new_other Bool) (w_k_new_other (_ BitVec 64))) Bool
  (=> (> ts_other snap)
      (not (rs_intersects_ws has_dr r_doc has_rr r_start r_end
                             has_w_other w_doc_other
                             w_has_old_other w_k_old_other
                             w_has_new_other w_k_new_other))))

; Transaction timestamps
(declare-const snap1 Int)
(declare-const ts1   Int)
(declare-const snap2 Int)
(declare-const ts2   Int)

; T1 ReadSet & WriteSet
(declare-const t1_has_dr    Bool)
(declare-const t1_r_doc     (_ BitVec 16))
(declare-const t1_has_rr    Bool)
(declare-const t1_r_lo      KeyBound)
(declare-const t1_r_hi      KeyBound)
(declare-const t1_has_w     Bool)
(declare-const t1_w_doc     (_ BitVec 16))
(declare-const t1_has_old_k Bool)
(declare-const t1_k_old     (_ BitVec 64))
(declare-const t1_has_new_k Bool)
(declare-const t1_k_new     (_ BitVec 64))
(declare-const t1_v_new     (_ BitVec 64))

; T2 ReadSet & WriteSet
(declare-const t2_has_dr    Bool)
(declare-const t2_r_doc     (_ BitVec 16))
(declare-const t2_has_rr    Bool)
(declare-const t2_r_lo      KeyBound)
(declare-const t2_r_hi      KeyBound)
(declare-const t2_has_w     Bool)
(declare-const t2_w_doc     (_ BitVec 16))
(declare-const t2_has_old_k Bool)
(declare-const t2_k_old     (_ BitVec 64))
(declare-const t2_has_new_k Bool)
(declare-const t2_k_new     (_ BitVec 64))
(declare-const t2_v_new     (_ BitVec 64))

; Monotonic commit log & causal snapshots
(assert (<= 0 snap1))
(assert (< snap1 ts1))
(assert (<= 0 snap2))
(assert (< snap2 ts2))
(assert (distinct ts1 ts2))

; Both T1 and T2 pass Concave's OCC commit validation against all earlier commits
; (A transaction validating at ts only checks commits with snap < ts_other < ts.)
(assert (=> (< ts2 ts1)
            (occ_valid snap1 ts2
                       t1_has_dr t1_r_doc t1_has_rr t1_r_lo t1_r_hi
                       t2_has_w t2_w_doc
                       t2_has_old_k t2_k_old t2_has_new_k t2_k_new)))
(assert (=> (< ts1 ts2)
            (occ_valid snap2 ts1
                       t2_has_dr t2_r_doc t2_has_rr t2_r_lo t2_r_hi
                       t1_has_w t1_w_doc
                       t1_has_old_k t1_k_old t1_has_new_k t1_k_new)))

; ----------------------------------------------------------------------------
; 4a. No Lost Updates:
;     Two concurrent RMW transactions on the same doc cannot both commit.
; ----------------------------------------------------------------------------
(echo "Proof 4a (No Lost Updates):")
(push)
(declare-const shared_doc (_ BitVec 16))
(assert (< snap1 ts2))
(assert (< snap2 ts1))
(assert t1_has_dr) (assert (= t1_r_doc shared_doc))
(assert t1_has_w)  (assert (= t1_w_doc shared_doc))
(assert t2_has_dr) (assert (= t2_r_doc shared_doc))
(assert t2_has_w)  (assert (= t2_w_doc shared_doc))
(check-sat)
(pop)

; ----------------------------------------------------------------------------
; 4b. No Write Skew:
;     Concurrent T1 (reads d1, writes d2) and T2 (reads d2, writes d1)
;     cannot both commit (covers both point-read and range-read write skew).
; ----------------------------------------------------------------------------
(echo "Proof 4b (No Write Skew - doc reads):")
(push)
(declare-const d1 (_ BitVec 16))
(declare-const d2 (_ BitVec 16))
(assert (< snap1 ts2))
(assert (< snap2 ts1))
(assert t1_has_dr) (assert (= t1_r_doc d1))
(assert t1_has_w)  (assert (= t1_w_doc d2))
(assert t2_has_dr) (assert (= t2_r_doc d2))
(assert t2_has_w)  (assert (= t2_w_doc d1))
(check-sat)
(pop)

(echo "Proof 4b-range (No Write Skew - index range reads):")
(push)
(assert (< snap1 ts2))
(assert (< snap2 ts1))
(assert t1_has_rr) (assert t2_has_w)
(assert (or (and t2_has_old_k (contains_key t1_r_lo t1_r_hi t2_k_old))
            (and t2_has_new_k (contains_key t1_r_lo t1_r_hi t2_k_new))))
(assert t2_has_rr) (assert t1_has_w)
(assert (or (and t1_has_old_k (contains_key t2_r_lo t2_r_hi t1_k_old))
            (and t1_has_new_k (contains_key t2_r_lo t2_r_hi t1_k_new))))
(check-sat)
(pop)

; ----------------------------------------------------------------------------
; 4c. No Phantom Anomalies (Insert / Update / Delete into scanned range):
;     If T1 performs a range scan [t1_r_lo, t1_r_hi] at snap1, and T2 commits
;     after snap1 (ts2 > snap1) before T1 (ts2 < ts1) writing a doc whose
;     pre-image or post-image key falls inside T1's scanned range, T1 must abort.
; ----------------------------------------------------------------------------
(echo "Proof 4c (No Phantom Reads - insert/update/delete):")
(push)
(assert (< snap1 ts2))
(assert (< ts2 ts1))
(assert t1_has_rr)
(assert t2_has_w)
(assert (or (and t2_has_old_k (contains_key t1_r_lo t1_r_hi t2_k_old))
            (and t2_has_new_k (contains_key t1_r_lo t1_r_hi t2_k_new))))
(check-sat)
(pop)

; ----------------------------------------------------------------------------
; 4d. General 2-Transaction Serializability (Commit-Order Equivalence):
;     Model the full database state over inserts, updates, and deletes:
;       exists0 : DocId -> Bool
;       vals0   : DocId -> Val64
;       keys0   : DocId -> Key64
;     Assume T1 and T2 execute concurrently from base snapshot S0
;     (snap1 < ts2 and snap2 < ts1).
;     Prove that in the commit-order serial execution:
;       - If ts1 < ts2: running T2 on S_after_T1 yields IDENTICAL doc-read
;         (existence + value) AND IDENTICAL range-scan results (for EVERY doc d,
;         both range membership and observed (key, val)) as S0!
;       - Symmetrically if ts2 < ts1: running T1 on S_after_T2 yields IDENTICAL
;         doc-read and range-scan results as S0!
;     Hence there ALWAYS exists an equivalent serial execution order.
; ----------------------------------------------------------------------------
(echo "Proof 4d (General 2-Tx Commit-Order Serializability over DB Arrays):")
(push)

(declare-const exists0 (Array (_ BitVec 16) Bool))
(declare-const vals0   (Array (_ BitVec 16) (_ BitVec 64)))
(declare-const keys0   (Array (_ BitVec 16) (_ BitVec 64)))

; Concurrent execution from base snapshot S0
(assert (< snap1 ts2))
(assert (< snap2 ts1))

; Pre-image keys recorded in WriteSet match S0's existence & key
(assert (= t1_has_old_k (select exists0 t1_w_doc)))
(assert (= t1_k_old     (select keys0   t1_w_doc)))
(assert (= t2_has_old_k (select exists0 t2_w_doc)))
(assert (= t2_k_old     (select keys0   t2_w_doc)))

; State after applying T1 to S0 (supports insert, update, delete)
(define-fun exists_after_1 () (Array (_ BitVec 16) Bool)
  (ite t1_has_w (store exists0 t1_w_doc t1_has_new_k) exists0))
(define-fun vals_after_1 () (Array (_ BitVec 16) (_ BitVec 64))
  (ite t1_has_w (store vals0 t1_w_doc t1_v_new) vals0))
(define-fun keys_after_1 () (Array (_ BitVec 16) (_ BitVec 64))
  (ite t1_has_w (store keys0 t1_w_doc t1_k_new) keys0))

; State after applying T2 to S0 (supports insert, update, delete)
(define-fun exists_after_2 () (Array (_ BitVec 16) Bool)
  (ite t2_has_w (store exists0 t2_w_doc t2_has_new_k) exists0))
(define-fun vals_after_2 () (Array (_ BitVec 16) (_ BitVec 64))
  (ite t2_has_w (store vals0 t2_w_doc t2_v_new) vals0))
(define-fun keys_after_2 () (Array (_ BitVec 16) (_ BitVec 64))
  (ite t2_has_w (store keys0 t2_w_doc t2_k_new) keys0))

; Arbitrary probe document `d` to check whether range-scan observations differ
(declare-const d (_ BitVec 16))

(define-fun in_range_0 ((lo KeyBound) (hi KeyBound) (doc (_ BitVec 16))) Bool
  (and (select exists0 doc) (contains_key lo hi (select keys0 doc))))
(define-fun in_range_after_1 ((lo KeyBound) (hi KeyBound) (doc (_ BitVec 16))) Bool
  (and (select exists_after_1 doc) (contains_key lo hi (select keys_after_1 doc))))
(define-fun in_range_after_2 ((lo KeyBound) (hi KeyBound) (doc (_ BitVec 16))) Bool
  (and (select exists_after_2 doc) (contains_key lo hi (select keys_after_2 doc))))

; Observation equivalence of T2 on S_after_1 vs S0 (serial order T1 ; T2)
(define-fun t2_obs_equiv_after_1 () Bool
  (and
    (=> t2_has_dr
        (and (= (select exists_after_1 t2_r_doc) (select exists0 t2_r_doc))
             (=> (select exists0 t2_r_doc)
                 (= (select vals_after_1 t2_r_doc) (select vals0 t2_r_doc)))))
    (=> t2_has_rr
        (and
          (= (in_range_after_1 t2_r_lo t2_r_hi d) (in_range_0 t2_r_lo t2_r_hi d))
          (=> (in_range_0 t2_r_lo t2_r_hi d)
              (and (= (select keys_after_1 d) (select keys0 d))
                   (= (select vals_after_1 d) (select vals0 d))))))))

; Observation equivalence of T1 on S_after_2 vs S0 (serial order T2 ; T1)
(define-fun t1_obs_equiv_after_2 () Bool
  (and
    (=> t1_has_dr
        (and (= (select exists_after_2 t1_r_doc) (select exists0 t1_r_doc))
             (=> (select exists0 t1_r_doc)
                 (= (select vals_after_2 t1_r_doc) (select vals0 t1_r_doc)))))
    (=> t1_has_rr
        (and
          (= (in_range_after_2 t1_r_lo t1_r_hi d) (in_range_0 t1_r_lo t1_r_hi d))
          (=> (in_range_0 t1_r_lo t1_r_hi d)
              (and (= (select keys_after_2 d) (select keys0 d))
                   (= (select vals_after_2 d) (select vals0 d))))))))

; Negate serializability in commit order: search for any counterexample!
(assert (not (and (=> (< ts1 ts2) t2_obs_equiv_after_1)
                  (=> (< ts2 ts1) t1_obs_equiv_after_2))))
(check-sat)
(pop)

(pop)
