use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{CoreError, CoreResult};

const TAG_NULL: u8 = 0x01;
const TAG_BOOL: u8 = 0x02;
const TAG_INT: u8 = 0x03;
const TAG_FLOAT: u8 = 0x04;
const TAG_STR: u8 = 0x05;
const TAG_ID: u8 = 0x06;

/// Typed index key component supporting deterministic lexicographic byte encoding.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum IndexValue {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Id(String),
}

impl IndexValue {
    /// Convert a JSON value extracted from a document field into an `IndexValue`.
    pub fn from_json(value: &Value) -> CoreResult<Self> {
        match value {
            Value::Null => Ok(Self::Null),
            Value::Bool(b) => Ok(Self::Bool(*b)),
            Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    Ok(Self::Int(i))
                } else if let Some(u) = n.as_u64() {
                    i64::try_from(u)
                        .map(Self::Int)
                        .or_else(|_| Ok(Self::Float(u as f64)))
                } else if let Some(f) = n.as_f64() {
                    if f.is_nan() {
                        Err(CoreError::InvalidKey("NaN cannot be indexed".into()))
                    } else {
                        Ok(Self::Float(f))
                    }
                } else {
                    Err(CoreError::InvalidKey(format!("unsupported number: {n}")))
                }
            }
            Value::String(s) => Ok(Self::Str(s.clone())),
            _ => Err(CoreError::InvalidKey(format!(
                "non-scalar JSON value cannot be indexed: {value}"
            ))),
        }
    }
}

/// Encode a composite index key tuple into an order-preserving byte sequence.
pub fn encode_key(values: &[IndexValue]) -> CoreResult<Vec<u8>> {
    let mut out = Vec::with_capacity(values.len() * 16);
    for val in values {
        encode_value(val, &mut out)?;
    }
    Ok(out)
}

/// Exclusive upper bound covering every composite key starting with `prefix`.
pub fn encode_prefix_upper_bound(prefix: &[IndexValue]) -> CoreResult<Vec<u8>> {
    let mut bytes = encode_key(prefix)?;
    bytes.push(0xFF);
    Ok(bytes)
}

fn encode_value(val: &IndexValue, out: &mut Vec<u8>) -> CoreResult<()> {
    match val {
        IndexValue::Null => {
            out.push(TAG_NULL);
        }
        IndexValue::Bool(b) => {
            out.push(TAG_BOOL);
            out.push(u8::from(*b));
        }
        IndexValue::Int(i) => {
            out.push(TAG_INT);
            let ordered = (*i as u64) ^ (1u64 << 63);
            out.extend_from_slice(&ordered.to_be_bytes());
        }
        IndexValue::Float(f) => {
            if f.is_nan() {
                return Err(CoreError::InvalidKey("NaN cannot be indexed".into()));
            }
            out.push(TAG_FLOAT);
            let canonical = if *f == 0.0 { 0.0f64 } else { *f };
            let bits = canonical.to_bits();
            let ordered = if (bits & (1u64 << 63)) != 0 {
                !bits
            } else {
                bits ^ (1u64 << 63)
            };
            out.extend_from_slice(&ordered.to_be_bytes());
        }
        IndexValue::Str(s) => {
            out.push(TAG_STR);
            encode_escaped_bytes(s.as_bytes(), out);
        }
        IndexValue::Id(id) => {
            out.push(TAG_ID);
            encode_escaped_bytes(id.as_bytes(), out);
        }
    }
    Ok(())
}

fn encode_escaped_bytes(bytes: &[u8], out: &mut Vec<u8>) {
    for &b in bytes {
        if b == 0x00 {
            out.push(0x00);
            out.push(0xFF);
        } else {
            out.push(b);
        }
    }
    out.push(0x00);
    out.push(0x00);
}

/// Decode an encoded composite index key back into its `IndexValue` components.
pub fn decode_key(mut bytes: &[u8]) -> CoreResult<Vec<IndexValue>> {
    let mut values = Vec::new();
    while !bytes.is_empty() {
        let tag = bytes[0];
        bytes = &bytes[1..];
        match tag {
            TAG_NULL => values.push(IndexValue::Null),
            TAG_BOOL => {
                if bytes.is_empty() {
                    return Err(CoreError::InvalidKey("truncated bool".into()));
                }
                let b = match bytes[0] {
                    0 => false,
                    1 => true,
                    other => {
                        return Err(CoreError::InvalidKey(format!(
                            "invalid bool byte: {other}"
                        )))
                    }
                };
                bytes = &bytes[1..];
                values.push(IndexValue::Bool(b));
            }
            TAG_INT => {
                if bytes.len() < 8 {
                    return Err(CoreError::InvalidKey("truncated int".into()));
                }
                let raw = u64::from_be_bytes(bytes[..8].try_into().unwrap());
                bytes = &bytes[8..];
                values.push(IndexValue::Int((raw ^ (1u64 << 63)) as i64));
            }
            TAG_FLOAT => {
                if bytes.len() < 8 {
                    return Err(CoreError::InvalidKey("truncated float".into()));
                }
                let ordered = u64::from_be_bytes(bytes[..8].try_into().unwrap());
                bytes = &bytes[8..];
                let bits = if (ordered & (1u64 << 63)) != 0 {
                    ordered ^ (1u64 << 63)
                } else {
                    !ordered
                };
                values.push(IndexValue::Float(f64::from_bits(bits)));
            }
            TAG_STR => {
                let (s, rest) = decode_escaped_str(bytes)?;
                bytes = rest;
                values.push(IndexValue::Str(s));
            }
            TAG_ID => {
                let (s, rest) = decode_escaped_str(bytes)?;
                bytes = rest;
                values.push(IndexValue::Id(s));
            }
            other => {
                return Err(CoreError::InvalidKey(format!(
                    "unknown index value tag: 0x{other:02x}"
                )))
            }
        }
    }
    Ok(values)
}

fn decode_escaped_str(bytes: &[u8]) -> CoreResult<(String, &[u8])> {
    let mut raw = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x00 {
            if i + 1 >= bytes.len() {
                return Err(CoreError::InvalidKey("truncated string escape".into()));
            }
            match bytes[i + 1] {
                0x00 => {
                    let s = String::from_utf8(raw)
                        .map_err(|e| CoreError::InvalidKey(format!("invalid utf8: {e}")))?;
                    return Ok((s, &bytes[i + 2..]));
                }
                0xFF => {
                    raw.push(0x00);
                    i += 2;
                }
                other => {
                    return Err(CoreError::InvalidKey(format!(
                        "invalid string escape 0x00 0x{other:02x}"
                    )))
                }
            }
        } else {
            raw.push(bytes[i]);
            i += 1;
        }
    }
    Err(CoreError::InvalidKey("unterminated string".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ints_preserve_signed_order() {
        let nums = [i64::MIN, -1000, -1, 0, 1, 42, i64::MAX];
        let encoded: Vec<Vec<u8>> = nums
            .iter()
            .map(|&n| encode_key(&[IndexValue::Int(n)]).unwrap())
            .collect();
        for w in encoded.windows(2) {
            assert!(w[0] < w[1]);
        }
        for (&n, bytes) in nums.iter().zip(&encoded) {
            assert_eq!(decode_key(bytes).unwrap(), vec![IndexValue::Int(n)]);
        }
    }

    #[test]
    fn floats_preserve_order_and_canonicalize_zero() {
        let vals = [f64::NEG_INFINITY, -100.5, -0.001, 0.0, 0.001, 42.25, f64::INFINITY];
        let encoded: Vec<Vec<u8>> = vals
            .iter()
            .map(|&f| encode_key(&[IndexValue::Float(f)]).unwrap())
            .collect();
        for w in encoded.windows(2) {
            assert!(w[0] < w[1]);
        }
        assert_eq!(
            encode_key(&[IndexValue::Float(-0.0)]).unwrap(),
            encode_key(&[IndexValue::Float(0.0)]).unwrap()
        );
        assert!(encode_key(&[IndexValue::Float(f64::NAN)]).is_err());
    }

    #[test]
    fn strings_preserve_order_including_embedded_nul() {
        let strs = ["", "\0", "\0a", "a", "a\0", "a\0b", "aa", "b"];
        let encoded: Vec<Vec<u8>> = strs
            .iter()
            .map(|&s| encode_key(&[IndexValue::Str(s.into())]).unwrap())
            .collect();
        for w in encoded.windows(2) {
            assert!(w[0] < w[1], "failed order for {:?} vs {:?}", w[0], w[1]);
        }
        for (&s, bytes) in strs.iter().zip(&encoded) {
            assert_eq!(decode_key(bytes).unwrap(), vec![IndexValue::Str(s.into())]);
        }
    }

    #[test]
    fn composite_prefix_upper_bound_brackets_exact_prefix() {
        let prefix = encode_key(&[IndexValue::Str("room-a".into())]).unwrap();
        let upper = encode_prefix_upper_bound(&[IndexValue::Str("room-a".into())]).unwrap();

        let in_room_a =
            encode_key(&[IndexValue::Str("room-a".into()), IndexValue::Int(999)]).unwrap();
        let in_room_a_nul =
            encode_key(&[IndexValue::Str("room-a\0".into()), IndexValue::Int(0)]).unwrap();
        let in_room_b =
            encode_key(&[IndexValue::Str("room-b".into()), IndexValue::Int(0)]).unwrap();

        assert!(prefix <= in_room_a && in_room_a < upper);
        assert!(upper < in_room_a_nul);
        assert!(upper < in_room_b);
    }
}
