/-
  Concave KeyCodec Formal Specification & Proofs
  Models `zig/core/key.zig` in pure Lean 4 (`Init` only, zero `sorry`, zero custom axioms).

  Verified properties:
  1. `encodeEscaped_order`: Order-isomorphism of NUL-escaped byte strings (`0x00 -> [0x00, 0xFF]`, terminated by `[0x00, 0x00]`).
  2. `encodeEscaped_prefix_free`: Prefix-freeness / unique decodability of `encodeEscaped`.
  3. `encodeInt64_order`: Order-isomorphism of big-endian `(raw ^ (1 << 63))` encoding for all `Int64`.
  4. `encodeKey_order` & `encodeKey_injective`: Full order-isomorphism and injectivity for composite tuples `List KeyVal`.
  5. `prefixUpperBound_brackets`: Exact bracketing of `encodePrefixUpperBound p = encodeKey p ++ [0xFF]`.
-/

namespace Concave.KeyCodec

/-! ## Lexicographic order on byte sequences (`List UInt8`) -/

inductive lexLt : List UInt8 → List UInt8 → Prop where
  | nil_cons (b : UInt8) (bs : List UInt8) : lexLt [] (b :: bs)
  | head_lt {a b : UInt8} (as bs : List UInt8) (h : a < b) : lexLt (a :: as) (b :: bs)
  | head_eq {a : UInt8} {as bs : List UInt8} (h : lexLt as bs) : lexLt (a :: as) (a :: bs)

theorem lexLt_irrefl : ∀ xs : List UInt8, ¬ lexLt xs xs
  | [], h => nomatch h
  | _ :: _, .head_lt _ _ hlt => Nat.lt_irrefl _ hlt
  | _ :: xs, .head_eq h => lexLt_irrefl xs h

theorem lexLt_trans : ∀ {xs ys zs : List UInt8}, lexLt xs ys → lexLt ys zs → lexLt xs zs
  | [], _ :: _, _ :: _, .nil_cons _ _, _ => .nil_cons _ _
  | _ :: _, _ :: _, _ :: _, .head_lt _ _ h1, .head_lt _ _ h2 =>
      .head_lt _ _ (Nat.lt_trans h1 h2)
  | _ :: _, _ :: _, _ :: _, .head_lt _ _ h1, .head_eq _ =>
      .head_lt _ _ h1
  | _ :: _, _ :: _, _ :: _, .head_eq _, .head_lt _ _ h2 =>
      .head_lt _ _ h2
  | _ :: _, _ :: _, _ :: _, .head_eq h1, .head_eq h2 =>
      .head_eq (lexLt_trans h1 h2)

theorem lexLt_asymm {xs ys : List UInt8} (h1 : lexLt xs ys) (h2 : lexLt ys xs) : False :=
  lexLt_irrefl xs (lexLt_trans h1 h2)

private theorem uint8_eq_of_toNat_eq {a b : UInt8} (h : a.toNat = b.toNat) : a = b := by
  exact UInt8.eq_of_toBitVec_eq (BitVec.eq_of_toNat_eq h)

theorem lexLt_trichotomy : ∀ xs ys : List UInt8, lexLt xs ys ∨ xs = ys ∨ lexLt ys xs
  | [], [] => Or.inr (Or.inl rfl)
  | [], b :: bs => Or.inl (.nil_cons b bs)
  | a :: as, [] => Or.inr (Or.inr (.nil_cons a as))
  | a :: as, b :: bs =>
      if hlt : a < b then
        Or.inl (.head_lt as bs hlt)
      else if hgt : b < a then
        Or.inr (Or.inr (.head_lt bs as hgt))
      else
        have heq : a = b := by
          have ha : ¬ a.toNat < b.toNat := by simpa [UInt8.lt_iff_toNat_lt] using hlt
          have hb : ¬ b.toNat < a.toNat := by simpa [UInt8.lt_iff_toNat_lt] using hgt
          exact uint8_eq_of_toNat_eq (by omega)
        match heq, lexLt_trichotomy as bs with
        | rfl, Or.inl h => Or.inl (.head_eq h)
        | rfl, Or.inr (Or.inl rfl) => Or.inr (Or.inl rfl)
        | rfl, Or.inr (Or.inr h) => Or.inr (Or.inr (.head_eq h))

theorem lexLt_append_left : ∀ (p xs ys : List UInt8), lexLt xs ys → lexLt (p ++ xs) (p ++ ys)
  | [], _, _, h => h
  | _ :: p, xs, ys, h => .head_eq (lexLt_append_left p xs ys h)

theorem lexLt_append_left_cancel : ∀ (p xs ys : List UInt8), lexLt (p ++ xs) (p ++ ys) → lexLt xs ys
  | [], _, _, h => h
  | _ :: _, _, _, .head_lt _ _ hlt => absurd hlt (Nat.lt_irrefl _)
  | _ :: p, xs, ys, .head_eq h => lexLt_append_left_cancel p xs ys h

theorem lexLt_append_nonempty (p s : List UInt8) (hs : s ≠ []) : lexLt p (p ++ s) := by
  induction p with
  | nil =>
    cases s with
    | nil => exact absurd rfl hs
    | cons b bs => exact .nil_cons b bs
  | cons _ _ ih => exact .head_eq ih

/-! ## Key tags and values matching `zig/core/key.zig` -/

def TAG_NULL : UInt8 := 0x01
def TAG_BOOL : UInt8 := 0x02
def TAG_INT  : UInt8 := 0x03
def TAG_STR  : UInt8 := 0x05
def TAG_ID   : UInt8 := 0x06

inductive KeyVal where
  | null
  | bool (b : Bool)
  | int64 (n : Int64)
  | bytes (bs : List UInt8)
  | id (bs : List UInt8)
deriving DecidableEq, Repr

/-! ## NUL-escaped byte encoding (`0x00 -> [0x00, 0xFF]`, terminated by `[0x00, 0x00]`) -/

def encodeEscaped : List UInt8 → List UInt8
  | [] => [0x00, 0x00]
  | b :: bs =>
    if b == 0x00 then 0x00 :: 0xFF :: encodeEscaped bs
    else b :: encodeEscaped bs

private theorem uint8_pos_of_ne_zero {b : UInt8} (h : b ≠ 0x00) : (0x00 : UInt8) < b := by
  rw [UInt8.lt_iff_toNat_lt]
  have hne : b.toNat ≠ 0 := fun h0 => h (uint8_eq_of_toNat_eq h0)
  change 0 < b.toNat
  omega

/-- Suffix-invariant order preservation of `encodeEscaped`:
    if `lexLt a b`, then `encodeEscaped a ++ r1 < encodeEscaped b ++ r2` for ALL suffixes `r1, r2`. -/
theorem encodeEscaped_lexLt_append :
    ∀ {a b : List UInt8}, lexLt a b → ∀ r1 r2 : List UInt8,
      lexLt (encodeEscaped a ++ r1) (encodeEscaped b ++ r2)
  | [], b :: _, .nil_cons _ _, r1, r2 => by
      simp only [encodeEscaped]
      split
      · simp only [List.cons_append, List.nil_append]
        exact .head_eq (.head_lt _ _ (by decide))
      · rename_i hne
        have hb : b ≠ 0x00 := by simpa using hne
        simp only [List.cons_append, List.nil_append]
        exact .head_lt _ _ (uint8_pos_of_ne_zero hb)
  | a :: _, b :: _, .head_lt _ _ hlt, r1, r2 => by
      have hb_ne : b ≠ 0x00 := by
        intro hb0
        subst hb0
        rw [UInt8.lt_iff_toNat_lt] at hlt
        change a.toNat < 0 at hlt
        omega
      have hbeq : (b == 0x00) = false := beq_false_of_ne hb_ne
      simp only [encodeEscaped, hbeq, Bool.false_eq_true, ↓reduceIte]
      split
      · rename_i ha0
        have ha : a = 0x00 := by simpa using ha0
        subst ha
        simp only [List.cons_append]
        exact .head_lt _ _ hlt
      · simp only [List.cons_append]
        exact .head_lt _ _ hlt
  | _ :: _, _ :: _, .head_eq hrest, r1, r2 => by
      simp only [encodeEscaped]
      split
      · simp only [List.cons_append]
        exact .head_eq (.head_eq (encodeEscaped_lexLt_append hrest r1 r2))
      · simp only [List.cons_append]
        exact .head_eq (encodeEscaped_lexLt_append hrest r1 r2)

/-- **Theorem 1 (`encodeEscaped_order`)**:
    NUL-escaped byte encoding is a strict order-isomorphism on `List UInt8`. -/
theorem encodeEscaped_order (a b : List UInt8) :
    lexLt a b ↔ lexLt (encodeEscaped a) (encodeEscaped b) := by
  constructor
  · intro h
    simpa using encodeEscaped_lexLt_append h [] []
  · intro h
    rcases lexLt_trichotomy a b with hlt | rfl | hgt
    · exact hlt
    · exact absurd h (lexLt_irrefl _)
    · exact absurd (encodeEscaped_lexLt_append hgt [] []) (by
        intro hba
        exact lexLt_asymm h (by simpa using hba))

/-- Universal prefix-freeness (unique decodability) of `encodeEscaped`. -/
theorem encodeEscaped_append_inj :
    ∀ {a b r1 r2 : List UInt8},
      encodeEscaped a ++ r1 = encodeEscaped b ++ r2 → a = b ∧ r1 = r2 := by
  intro a b r1 r2 heq
  rcases lexLt_trichotomy a b with hlt | rfl | hgt
  · exact absurd heq (by
      intro h
      have := encodeEscaped_lexLt_append hlt r1 r2
      rw [h] at this
      exact lexLt_irrefl _ this)
  · exact ⟨rfl, List.append_cancel_left heq⟩
  · exact absurd heq (by
      intro h
      have := encodeEscaped_lexLt_append hgt r2 r1
      rw [← h] at this
      exact lexLt_irrefl _ this)

/-- **Theorem 2 (`encodeEscaped_prefix_free`)**:
    No valid `encodeEscaped a` is a strict prefix of `encodeEscaped b`. -/
theorem encodeEscaped_prefix_free (a b s : List UInt8) (hs : s ≠ []) :
    encodeEscaped a ++ s ≠ encodeEscaped b := by
  intro h
  have h' : encodeEscaped a ++ s = encodeEscaped b ++ [] := by simpa using h
  have ⟨_, hs0⟩ := encodeEscaped_append_inj h'
  exact hs hs0

/-! ## Signed 64-bit big-endian order-preserving encoding (`zig/core/key.zig`) -/

def encodeUInt64BE (u : UInt64) : List UInt8 :=
  [ (u >>> 56).toUInt8,
    (u >>> 48).toUInt8,
    (u >>> 40).toUInt8,
    (u >>> 32).toUInt8,
    (u >>> 24).toUInt8,
    (u >>> 16).toUInt8,
    (u >>>  8).toUInt8,
    u.toUInt8 ]

def signFlipMask : UInt64 := (1 : UInt64) <<< 63

def encodeInt64 (n : Int64) : List UInt8 :=
  encodeUInt64BE (n.toUInt64 ^^^ signFlipMask)

/-- General bit-flipping identity: for any `k` and `x < 2^(k+1)`,
    `x ^^^ 2^k = if x < 2^k then x + 2^k else x - 2^k`. -/
private theorem nat_xor_two_pow (k x : Nat) (hx : x < 2 ^ (k + 1)) :
    x ^^^ 2 ^ k = if x < 2 ^ k then x + 2 ^ k else x - 2 ^ k := by
  have hpow2 : 2 ^ (k + 1) = 2 ^ k + 2 ^ k := by
    rw [Nat.pow_succ]; omega
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_xor, Nat.testBit_two_pow]
  by_cases hlt : x < 2 ^ k
  · simp only [hlt, ↓reduceIte]
    by_cases hi : k = i
    · subst hi
      have hxk : x.testBit k = false := Nat.testBit_lt_two_pow hlt
      have hadd : (x + 2 ^ k).testBit k = true := by
        rw [Nat.testBit, Nat.shiftRight_eq_div_pow]
        have hpos : 0 < 2 ^ k := Nat.two_pow_pos k
        have hdiv : (x + 2 ^ k) / 2 ^ k = 1 := by
          rw [Nat.add_div_right _ hpos, Nat.div_eq_of_lt hlt]
        rw [hdiv]
        rfl
      simp [hxk, hadd]
    · simp only [hi, decide_false, Bool.bne_false]
      by_cases hik : i < k
      · rw [Nat.testBit, Nat.testBit, Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow]
        have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
        have hdvd : 2 ^ (i + 1) ∣ 2 ^ k := Nat.pow_dvd_pow 2 (by omega)
        obtain ⟨m, hm⟩ := hdvd
        have hm' : 2 ^ k = 2 ^ i * (2 * m) := by
          rw [hm, Nat.pow_succ, Nat.mul_assoc]
        have hq : (x + 2 ^ k) / 2 ^ i = x / 2 ^ i + 2 * m := by
          rw [hm', Nat.add_mul_div_left _ _ hpos]
        rw [hq]
        simp [Nat.add_mod]
      · have hgt : k < i := by omega
        have h1 : x < 2 ^ i := Nat.lt_trans hlt (Nat.pow_lt_pow_right (by omega) hgt)
        have h2 : x + 2 ^ k < 2 ^ i := by
          have : 2 ^ (k + 1) ≤ 2 ^ i := Nat.pow_le_pow_right (by omega) (by omega)
          omega
        rw [Nat.testBit_lt_two_pow h1, Nat.testBit_lt_two_pow h2]
  · simp only [hlt, ↓reduceIte]
    by_cases hi : k = i
    · subst hi
      have hxk : x.testBit k = true := by
        rw [Nat.testBit, Nat.shiftRight_eq_div_pow]
        have hpos : 0 < 2 ^ k := Nat.two_pow_pos k
        have hsub_lt : x - 2 ^ k < 2 ^ k := by omega
        have hdiv : x / 2 ^ k = 1 := by
          have hxeq : x = (x - 2 ^ k) + 2 ^ k := by omega
          conv => lhs; rw [hxeq]
          rw [Nat.add_div_right _ hpos, Nat.div_eq_of_lt hsub_lt]
        rw [hdiv]
        rfl
      have hsub : (x - 2 ^ k).testBit k = false := Nat.testBit_lt_two_pow (by omega)
      simp [hxk, hsub]
    · simp only [hi, decide_false, Bool.bne_false]
      by_cases hik : i < k
      · rw [Nat.testBit, Nat.testBit, Nat.shiftRight_eq_div_pow, Nat.shiftRight_eq_div_pow]
        have hpos : 0 < 2 ^ i := Nat.two_pow_pos i
        have hdvd : 2 ^ (i + 1) ∣ 2 ^ k := Nat.pow_dvd_pow 2 (by omega)
        obtain ⟨m, hm⟩ := hdvd
        have hm' : 2 ^ k = 2 ^ i * (2 * m) := by
          rw [hm, Nat.pow_succ, Nat.mul_assoc]
        have hq : x / 2 ^ i = (x - 2 ^ k) / 2 ^ i + 2 * m := by
          have hxeq : x = (x - 2 ^ k) + 2 ^ i * (2 * m) := by omega
          conv => lhs; rw [hxeq]
          rw [Nat.add_mul_div_left _ _ hpos]
        rw [hq]
        simp [Nat.add_mod]
      · have hgt : k < i := by omega
        have h1 : x < 2 ^ i := Nat.lt_of_lt_of_le hx (Nat.pow_le_pow_right (by omega) (by omega))
        have h2 : x - 2 ^ k < 2 ^ i := by omega
        rw [Nat.testBit_lt_two_pow h1, Nat.testBit_lt_two_pow h2]

private theorem signFlip_toInt_eq (n : Int64) :
    ((n.toUInt64 ^^^ signFlipMask).toNat : Int) = n.toInt + 2 ^ 63 := by
  have hmask : signFlipMask.toNat = 2 ^ 63 := by decide
  rw [UInt64.toNat_xor, hmask]
  have hlt64 : n.toUInt64.toNat < 2 ^ 64 := n.toUInt64.toBitVec.isLt
  rw [nat_xor_two_pow 63 n.toUInt64.toNat hlt64]
  have hbv : n.toInt = n.toBitVec.toInt := rfl
  have hnat : n.toUInt64.toNat = n.toBitVec.toNat := by
    rw [← Int64.toBitVec_toUInt64]
    rfl
  rw [hbv, BitVec.toInt_eq_toNat_cond, ← hnat]
  by_cases hlt : n.toUInt64.toNat < 2 ^ 63
  · have h2 : 2 * n.toUInt64.toNat < 2 ^ 64 := by omega
    simp only [hlt, h2, ↓reduceIte]
    omega
  · have h2 : ¬ (2 * n.toUInt64.toNat < 2 ^ 64) := by omega
    simp only [hlt, h2, ↓reduceIte]
    omega

theorem signFlip_order (a b : Int64) :
    a < b ↔ (a.toUInt64 ^^^ signFlipMask) < (b.toUInt64 ^^^ signFlipMask) := by
  rw [Int64.lt_iff_toInt_lt, UInt64.lt_iff_toNat_lt]
  have ha := signFlip_toInt_eq a
  have hb := signFlip_toInt_eq b
  omega

/-- Generic big-endian `k`-byte encoding of a `Nat` (most significant byte first). -/
private def encodeNatBE : Nat → Nat → List UInt8
  | 0, _ => []
  | k + 1, x => encodeNatBE k (x / 256) ++ [UInt8.ofNat (x % 256)]

private theorem uint8_toNat_ofNat (n : Nat) : (UInt8.ofNat n).toNat = n % 256 :=
  BitVec.toNat_ofNat n 8

private theorem encodeNatBE_lexLt_append :
    ∀ (k x y : Nat), x < 256 ^ k → y < 256 ^ k → x < y →
      ∀ r1 r2 : List UInt8, lexLt (encodeNatBE k x ++ r1) (encodeNatBE k y ++ r2)
  | 0, x, y, hx, hy, hlt, _, _ => by
      simp only [Nat.pow_zero] at hx hy
      omega
  | k + 1, x, y, hx, hy, hlt, r1, r2 => by
      have hpow : 256 ^ (k + 1) = 256 ^ k * 256 := Nat.pow_succ 256 k
      have hxq : x / 256 < 256 ^ k := by rw [hpow] at hx; omega
      have hyq : y / 256 < 256 ^ k := by rw [hpow] at hy; omega
      simp only [encodeNatBE, List.append_assoc, List.singleton_append]
      by_cases hq : x / 256 < y / 256
      · exact encodeNatBE_lexLt_append k (x / 256) (y / 256) hxq hyq hq _ _
      · have hqeq : x / 256 = y / 256 := by omega
        have hmod : x % 256 < y % 256 := by omega
        rw [hqeq]
        apply lexLt_append_left
        apply lexLt.head_lt
        rw [UInt8.lt_iff_toNat_lt, uint8_toNat_ofNat, uint8_toNat_ofNat, Nat.mod_mod, Nat.mod_mod]
        exact hmod

private theorem uint64_shift_toUInt8_eq (u : UInt64) (s : UInt64) (hs : s.toNat < 64) :
    (u >>> s).toUInt8 = UInt8.ofNat ((u.toNat / 2 ^ s.toNat) % 256) := by
  apply uint8_eq_of_toNat_eq
  rw [UInt64.toNat_toUInt8, UInt64.toNat_shiftRight, Nat.mod_eq_of_lt hs,
      Nat.shiftRight_eq_div_pow, uint8_toNat_ofNat, Nat.mod_mod]

private theorem encodeUInt64BE_eq_encodeNatBE (u : UInt64) :
    encodeUInt64BE u = encodeNatBE 8 u.toNat := by
  have h56 := uint64_shift_toUInt8_eq u 56 (by decide)
  have h48 := uint64_shift_toUInt8_eq u 48 (by decide)
  have h40 := uint64_shift_toUInt8_eq u 40 (by decide)
  have h32 := uint64_shift_toUInt8_eq u 32 (by decide)
  have h24 := uint64_shift_toUInt8_eq u 24 (by decide)
  have h16 := uint64_shift_toUInt8_eq u 16 (by decide)
  have h8  := uint64_shift_toUInt8_eq u 8  (by decide)
  have h0  : u.toUInt8 = UInt8.ofNat (u.toNat % 256) := by
    apply uint8_eq_of_toNat_eq
    rw [UInt64.toNat_toUInt8, uint8_toNat_ofNat, Nat.mod_mod]
  simp only [encodeUInt64BE, encodeNatBE, List.nil_append, List.append_assoc, List.singleton_append]
  rw [h56, h48, h40, h32, h24, h16, h8, h0]
  have s56 : (56 : UInt64).toNat = 56 := rfl
  have s48 : (48 : UInt64).toNat = 48 := rfl
  have s40 : (40 : UInt64).toNat = 40 := rfl
  have s32 : (32 : UInt64).toNat = 32 := rfl
  have s24 : (24 : UInt64).toNat = 24 := rfl
  have s16 : (16 : UInt64).toNat = 16 := rfl
  have s8  : (8  : UInt64).toNat = 8  := rfl
  rw [s56, s48, s40, s32, s24, s16, s8]
  simp only [Nat.div_div_eq_div_mul]
  rfl

/-- Suffix-invariant order preservation of big-endian 8-byte `UInt64` encoding. -/
theorem encodeUInt64BE_lexLt_append (x y : UInt64) (h : x < y) (r1 r2 : List UInt8) :
    lexLt (encodeUInt64BE x ++ r1) (encodeUInt64BE y ++ r2) := by
  rw [encodeUInt64BE_eq_encodeNatBE, encodeUInt64BE_eq_encodeNatBE]
  have hx : x.toNat < 256 ^ 8 := x.toBitVec.isLt
  have hy : y.toNat < 256 ^ 8 := y.toBitVec.isLt
  exact encodeNatBE_lexLt_append 8 x.toNat y.toNat hx hy (UInt64.lt_iff_toNat_lt.mp h) r1 r2

theorem encodeInt64_lexLt_append (a b : Int64) (h : a < b) (r1 r2 : List UInt8) :
    lexLt (encodeInt64 a ++ r1) (encodeInt64 b ++ r2) :=
  encodeUInt64BE_lexLt_append _ _ ((signFlip_order a b).mp h) r1 r2

/-- **Theorem 3 (`encodeInt64_order`)**:
    Order-isomorphism of the `xor 0x8000_0000_0000_0000` big-endian encoding for all `Int64`. -/
theorem encodeInt64_order (a b : Int64) :
    a < b ↔ lexLt (encodeInt64 a) (encodeInt64 b) := by
  constructor
  · intro h
    simpa using encodeInt64_lexLt_append a b h [] []
  · intro h
    by_cases hlt : a < b
    · exact hlt
    · by_cases hgt : b < a
      · exact absurd (by simpa using encodeInt64_lexLt_append b a hgt [] []) (lexLt_asymm h)
      · have heq : a = b := by
          rw [Int64.lt_iff_toInt_lt] at hlt hgt
          exact Int64.toInt_inj.mp (by omega)
        subst heq
        exact absurd h (lexLt_irrefl _)

/-! ## Value and composite tuple encoding -/

def encodeValue : KeyVal → List UInt8
  | .null     => [TAG_NULL]
  | .bool b   => [TAG_BOOL, if b then 0x01 else 0x00]
  | .int64 n  => TAG_INT :: encodeInt64 n
  | .bytes bs => TAG_STR :: encodeEscaped bs
  | .id bs    => TAG_ID  :: encodeEscaped bs

def encodeKey : List KeyVal → List UInt8
  | [] => []
  | v :: vs => encodeValue v ++ encodeKey vs

def encodePrefixUpperBound (pre : List KeyVal) : List UInt8 :=
  encodeKey pre ++ [0xFF]

theorem encodeKey_append (p s : List KeyVal) :
    encodeKey (p ++ s) = encodeKey p ++ encodeKey s := by
  induction p with
  | nil => rfl
  | cons v vs ih => simp [encodeKey, ih, List.append_assoc]

/-! ## Strict total order on `KeyVal` and `List KeyVal` -/

def KeyVal.tag : KeyVal → UInt8
  | .null    => TAG_NULL
  | .bool _  => TAG_BOOL
  | .int64 _ => TAG_INT
  | .bytes _ => TAG_STR
  | .id _    => TAG_ID

def valLt : KeyVal → KeyVal → Prop
  | .null,     .null     => False
  | .bool a,   .bool b   => a = false ∧ b = true
  | .int64 a,  .int64 b  => a < b
  | .bytes a,  .bytes b  => lexLt a b
  | .id a,     .id b     => lexLt a b
  | x,         y         => x.tag < y.tag

inductive tupleLt : List KeyVal → List KeyVal → Prop where
  | nil_cons (v : KeyVal) (vs : List KeyVal) : tupleLt [] (v :: vs)
  | head_lt {v1 v2 : KeyVal} (vs1 vs2 : List KeyVal) (h : valLt v1 v2) :
      tupleLt (v1 :: vs1) (v2 :: vs2)
  | head_eq {v : KeyVal} {vs1 vs2 : List KeyVal} (h : tupleLt vs1 vs2) :
      tupleLt (v :: vs1) (v :: vs2)

theorem valLt_trichotomy (x y : KeyVal) : valLt x y ∨ x = y ∨ valLt y x := by
  cases x <;> cases y
  · exact Or.inr (Or.inl rfl)
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_BOOL])
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_INT])
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_STR])
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_ID])
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_BOOL]))
  · rename_i a b
    cases a <;> cases b
    · exact Or.inr (Or.inl rfl)
    · exact Or.inl ⟨rfl, rfl⟩
    · exact Or.inr (Or.inr ⟨rfl, rfl⟩)
    · exact Or.inr (Or.inl rfl)
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_BOOL, TAG_INT])
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_BOOL, TAG_STR])
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_BOOL, TAG_ID])
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_INT]))
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_BOOL, TAG_INT]))
  · rename_i a b
    by_cases hlt : a < b
    · exact Or.inl hlt
    · by_cases hgt : b < a
      · exact Or.inr (Or.inr hgt)
      · rw [Int64.lt_iff_toInt_lt] at hlt hgt
        exact Or.inr (Or.inl (congrArg KeyVal.int64 (Int64.toInt_inj.mp (by omega))))
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_INT, TAG_STR])
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_INT, TAG_ID])
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_STR]))
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_BOOL, TAG_STR]))
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_INT, TAG_STR]))
  · rename_i a b
    rcases lexLt_trichotomy a b with h | rfl | h
    · exact Or.inl h
    · exact Or.inr (Or.inl rfl)
    · exact Or.inr (Or.inr h)
  · exact Or.inl (by simp [valLt, KeyVal.tag, TAG_STR, TAG_ID])
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_NULL, TAG_ID]))
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_BOOL, TAG_ID]))
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_INT, TAG_ID]))
  · exact Or.inr (Or.inr (by simp [valLt, KeyVal.tag, TAG_STR, TAG_ID]))
  · rename_i a b
    rcases lexLt_trichotomy a b with h | rfl | h
    · exact Or.inl h
    · exact Or.inr (Or.inl rfl)
    · exact Or.inr (Or.inr h)

theorem tupleLt_trichotomy : ∀ xs ys : List KeyVal, tupleLt xs ys ∨ xs = ys ∨ tupleLt ys xs
  | [], [] => Or.inr (Or.inl rfl)
  | [], v :: vs => Or.inl (.nil_cons v vs)
  | v :: vs, [] => Or.inr (Or.inr (.nil_cons v vs))
  | x :: xs, y :: ys =>
      match valLt_trichotomy x y with
      | Or.inl h => Or.inl (.head_lt xs ys h)
      | Or.inr (Or.inr h) => Or.inr (Or.inr (.head_lt ys xs h))
      | Or.inr (Or.inl rfl) =>
          match tupleLt_trichotomy xs ys with
          | Or.inl h => Or.inl (.head_eq h)
          | Or.inr (Or.inl rfl) => Or.inr (Or.inl rfl)
          | Or.inr (Or.inr h) => Or.inr (Or.inr (.head_eq h))

/-- Every encoded `KeyVal` starts with its tag byte, which is strictly less than `0xFF`. -/
theorem encodeValue_head_lt_0xFF (v : KeyVal) :
    ∃ rest : List UInt8, encodeValue v = v.tag :: rest ∧ v.tag < 0xFF := by
  cases v with
  | null     => exact ⟨[], rfl, by simp [KeyVal.tag, TAG_NULL]⟩
  | bool b   => exact ⟨[if b then 0x01 else 0x00], rfl, by simp [KeyVal.tag, TAG_BOOL]⟩
  | int64 n  => exact ⟨encodeInt64 n, rfl, by simp [KeyVal.tag, TAG_INT]⟩
  | bytes bs => exact ⟨encodeEscaped bs, rfl, by simp [KeyVal.tag, TAG_STR]⟩
  | id bs    => exact ⟨encodeEscaped bs, rfl, by simp [KeyVal.tag, TAG_ID]⟩

theorem encodeValue_ne_nil (v : KeyVal) : encodeValue v ≠ [] := by
  obtain ⟨rest, heq, _⟩ := encodeValue_head_lt_0xFF v
  rw [heq]
  exact List.cons_ne_nil _ _

/-- Suffix-invariant order preservation for any single `KeyVal`. -/
theorem encodeValue_lexLt_append {v1 v2 : KeyVal} (h : valLt v1 v2) (r1 r2 : List UInt8) :
    lexLt (encodeValue v1 ++ r1) (encodeValue v2 ++ r2) := by
  cases v1 <;> cases v2
  · cases h
  · exact .head_lt _ _ (by decide)
  · exact .head_lt _ _ (by decide)
  · exact .head_lt _ _ (by decide)
  · exact .head_lt _ _ (by decide)
  · simp [valLt, KeyVal.tag, TAG_NULL, TAG_BOOL] at h
  · rcases h with ⟨rfl, rfl⟩
    exact .head_eq (.head_lt _ _ (by decide))
  · exact .head_lt _ _ (by decide)
  · exact .head_lt _ _ (by decide)
  · exact .head_lt _ _ (by decide)
  · simp [valLt, KeyVal.tag, TAG_NULL, TAG_INT] at h
  · simp [valLt, KeyVal.tag, TAG_BOOL, TAG_INT] at h
  · exact .head_eq (encodeInt64_lexLt_append _ _ h r1 r2)
  · exact .head_lt _ _ (by decide)
  · exact .head_lt _ _ (by decide)
  · simp [valLt, KeyVal.tag, TAG_NULL, TAG_STR] at h
  · simp [valLt, KeyVal.tag, TAG_BOOL, TAG_STR] at h
  · simp [valLt, KeyVal.tag, TAG_INT, TAG_STR] at h
  · exact .head_eq (encodeEscaped_lexLt_append h r1 r2)
  · exact .head_lt _ _ (by decide)
  · simp [valLt, KeyVal.tag, TAG_NULL, TAG_ID] at h
  · simp [valLt, KeyVal.tag, TAG_BOOL, TAG_ID] at h
  · simp [valLt, KeyVal.tag, TAG_INT, TAG_ID] at h
  · simp [valLt, KeyVal.tag, TAG_STR, TAG_ID] at h
  · exact .head_eq (encodeEscaped_lexLt_append h r1 r2)

/-- Forward direction of composite tuple order preservation. -/
theorem encodeKey_order_mp : ∀ {a b : List KeyVal}, tupleLt a b → lexLt (encodeKey a) (encodeKey b)
  | [], v :: _, .nil_cons _ _ => by
      obtain ⟨rest, heq, _⟩ := encodeValue_head_lt_0xFF v
      simp only [encodeKey, heq, List.cons_append]
      exact .nil_cons _ _
  | _ :: _, _ :: _, .head_lt _ _ h => by
      simp only [encodeKey]
      exact encodeValue_lexLt_append h _ _
  | v :: _, _ :: _, .head_eq h => by
      simp only [encodeKey]
      exact lexLt_append_left (encodeValue v) _ _ (encodeKey_order_mp h)

/-- **Theorem 4a (`encodeKey_order`)**:
    Composite tuple encoding `encodeKey : List KeyVal → List UInt8` is a strict order-isomorphism. -/
theorem encodeKey_order (a b : List KeyVal) :
    tupleLt a b ↔ lexLt (encodeKey a) (encodeKey b) := by
  constructor
  · exact encodeKey_order_mp
  · intro h
    rcases tupleLt_trichotomy a b with hlt | rfl | hgt
    · exact hlt
    · exact absurd h (lexLt_irrefl _)
    · exact absurd (encodeKey_order_mp hgt) (lexLt_asymm h)

/-- **Theorem 4b (`encodeKey_injective`)**:
    Composite tuple encoding `encodeKey` is injective. -/
theorem encodeKey_injective (a b : List KeyVal) (h : encodeKey a = encodeKey b) : a = b := by
  rcases tupleLt_trichotomy a b with hlt | heq | hgt
  · have hlt' := encodeKey_order_mp hlt
    rw [h] at hlt'
    exact absurd hlt' (lexLt_irrefl _)
  · exact heq
  · have hgt' := encodeKey_order_mp hgt
    rw [h] at hgt'
    exact absurd hgt' (lexLt_irrefl _)

/-! ## Prefix upper bound bracketing (`encodePrefixUpperBound p = encodeKey p ++ [0xFF]`) -/

/-- If `tupleLt p q` and `p` is NOT a prefix of `q`, then `p` and `q` diverge at some index
    with `valLt v1 v2`, so `encodePrefixUpperBound p < encodeKey (q ++ s)` for ANY suffix `s`. -/
theorem prefixUpperBound_lt_after :
    ∀ (p q s : List KeyVal), tupleLt p q → ¬ List.IsPrefix p q →
      lexLt (encodePrefixUpperBound p) (encodeKey (q ++ s))
  | [], q, _, _, hnp => absurd (List.nil_prefix (l := q)) hnp
  | _ :: p', _ :: q', s, .head_lt _ _ hv, _ => by
      simp only [encodePrefixUpperBound, encodeKey, List.cons_append, List.append_assoc]
      exact encodeValue_lexLt_append hv (encodeKey p' ++ [0xFF]) (encodeKey (q' ++ s))
  | v :: p', _ :: q', s, .head_eq hrest, hnp => by
      have hnp' : ¬ List.IsPrefix p' q' := by
        intro hp'
        exact hnp (List.cons_prefix_cons.mpr ⟨rfl, hp'⟩)
      simp only [encodePrefixUpperBound, encodeKey, List.cons_append, List.append_assoc]
      exact lexLt_append_left (encodeValue v) _ _ (prefixUpperBound_lt_after p' q' s hrest hnp')

/-- **Theorem 5 (`prefixUpperBound_brackets`)**:
    For any prefix `p` and non-empty suffix `s`:
    1. `encodeKey p < encodeKey (p ++ s)`
    2. `encodeKey (p ++ s) < encodePrefixUpperBound p`
    3. For any prefix `q` with `tupleLt p q` and `¬ List.IsPrefix p q`,
       `encodePrefixUpperBound p < encodeKey (q ++ s)`. -/
theorem prefixUpperBound_brackets (p s : List KeyVal) (hs : s ≠ []) :
    lexLt (encodeKey p) (encodeKey (p ++ s)) ∧
    lexLt (encodeKey (p ++ s)) (encodePrefixUpperBound p) ∧
    (∀ q : List KeyVal, tupleLt p q → ¬ List.IsPrefix p q →
      lexLt (encodePrefixUpperBound p) (encodeKey (q ++ s))) := by
  refine ⟨?_, ?_, ?_⟩
  · -- Part 1: encodeKey p < encodeKey (p ++ s)
    rw [encodeKey_append]
    cases s with
    | nil => exact absurd rfl hs
    | cons v _ =>
      apply lexLt_append_nonempty
      simp only [encodeKey]
      intro hnil
      exact encodeValue_ne_nil v (List.append_eq_nil_iff.mp hnil).1
  · -- Part 2: encodeKey (p ++ s) < encodePrefixUpperBound p
    rw [encodeKey_append, encodePrefixUpperBound]
    apply lexLt_append_left
    cases s with
    | nil => exact absurd rfl hs
    | cons v _ =>
      obtain ⟨rest, heq, hlt⟩ := encodeValue_head_lt_0xFF v
      simp only [encodeKey, heq, List.cons_append]
      exact .head_lt _ _ hlt
  · -- Part 3: for any q > p (not extending p), encodePrefixUpperBound p < encodeKey (q ++ s)
    intro q hlt hnp
    exact prefixUpperBound_lt_after p q s hlt hnp

/-- Same-length prefix corollary: if `p.length = q.length` and `tupleLt p q`,
    then `p` cannot be a prefix of `q`, so `encodePrefixUpperBound p < encodeKey (q ++ s)`. -/
theorem prefixUpperBound_lt_same_length (p q s : List KeyVal)
    (hlen : p.length = q.length) (hlt : tupleLt p q) :
    lexLt (encodePrefixUpperBound p) (encodeKey (q ++ s)) := by
  apply prefixUpperBound_lt_after p q s hlt
  intro ⟨t, ht⟩
  have htl : t.length = 0 := by
    have := congrArg List.length ht
    simp only [List.length_append] at this
    omega
  have ht0 : t = [] := List.eq_nil_of_length_eq_zero htl
  subst ht0
  simp only [List.append_nil] at ht
  subst ht
  exact lexLt_irrefl (encodeKey p) (encodeKey_order_mp hlt)

end Concave.KeyCodec

#print axioms Concave.KeyCodec.encodeEscaped_order
#print axioms Concave.KeyCodec.encodeEscaped_prefix_free
#print axioms Concave.KeyCodec.encodeInt64_order
#print axioms Concave.KeyCodec.encodeKey_order
#print axioms Concave.KeyCodec.encodeKey_injective
#print axioms Concave.KeyCodec.prefixUpperBound_brackets
#print axioms Concave.KeyCodec.prefixUpperBound_lt_same_length
