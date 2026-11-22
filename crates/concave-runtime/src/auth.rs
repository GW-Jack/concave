use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// Authenticated caller identity exposed to Roc via `ctx.auth!`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AuthIdentity {
    pub subject: String,
    pub issuer: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub claims: Value,
}

#[derive(Debug, Clone)]
pub struct AuthConfig {
    /// Optional HS256 JWT verification secret for production/custom JWTs.
    pub jwt_secret: Option<String>,
    /// Allow lightweight `dev:<subject>` or `dev:<subject>:<name>` tokens for local development.
    pub allow_dev_tokens: bool,
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            jwt_secret: std::env::var("CONCAVE_JWT_SECRET").ok(),
            allow_dev_tokens: true,
        }
    }
}

pub fn verify_token(config: &AuthConfig, raw_token: &str) -> Result<AuthIdentity, String> {
    let token = raw_token
        .strip_prefix("Bearer ")
        .unwrap_or(raw_token)
        .trim();
    if token.is_empty() {
        return Err("empty auth token".into());
    }

    if let Some(rest) = token.strip_prefix("dev:") {
        if !config.allow_dev_tokens {
            return Err("dev tokens are disabled".into());
        }
        let mut parts = rest.splitn(2, ':');
        let subject = parts.next().unwrap_or("").trim();
        if subject.is_empty() {
            return Err("invalid dev token: missing subject".into());
        }
        let name = parts
            .next()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| Some(subject.to_string()));
        return Ok(AuthIdentity {
            subject: subject.to_string(),
            issuer: "concave:dev".into(),
            name,
            claims: json!({ "dev": true }),
        });
    }

    let Some(secret) = &config.jwt_secret else {
        return Err("JWT verification secret is not configured".into());
    };

    verify_hs256_jwt(secret, token)
}

fn verify_hs256_jwt(secret: &str, token: &str) -> Result<AuthIdentity, String> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return Err("malformed JWT".into());
    }

    let header_bytes = URL_SAFE_NO_PAD
        .decode(parts[0])
        .map_err(|_| "invalid JWT header base64".to_string())?;
    let header: Value =
        serde_json::from_slice(&header_bytes).map_err(|_| "invalid JWT header JSON".to_string())?;
    if header.get("alg").and_then(|v| v.as_str()) != Some("HS256") {
        return Err("unsupported JWT alg (expected HS256)".into());
    }

    let signing_input = format!("{}.{}", parts[0], parts[1]);
    let sig_bytes = URL_SAFE_NO_PAD
        .decode(parts[2])
        .map_err(|_| "invalid JWT signature base64".to_string())?;
    let mut mac =
        HmacSha256::new_from_slice(secret.as_bytes()).map_err(|e| format!("hmac error: {e}"))?;
    mac.update(signing_input.as_bytes());
    mac.verify_slice(&sig_bytes)
        .map_err(|_| "invalid JWT signature".to_string())?;

    let payload_bytes = URL_SAFE_NO_PAD
        .decode(parts[1])
        .map_err(|_| "invalid JWT payload base64".to_string())?;
    let claims: Value = serde_json::from_slice(&payload_bytes)
        .map_err(|_| "invalid JWT payload JSON".to_string())?;

    if let Some(exp) = claims.get("exp").and_then(|v| v.as_i64()) {
        let now_secs = concave_core::now_millis() / 1000;
        if now_secs >= exp {
            return Err("JWT expired".into());
        }
    }

    let subject = claims
        .get("sub")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "JWT missing `sub` claim".to_string())?
        .to_string();
    let issuer = claims
        .get("iss")
        .and_then(|v| v.as_str())
        .unwrap_or("jwt")
        .to_string();
    let name = claims
        .get("name")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    Ok(AuthIdentity {
        subject,
        issuer,
        name,
        claims,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifies_dev_token() {
        let cfg = AuthConfig {
            jwt_secret: None,
            allow_dev_tokens: true,
        };
        let id = verify_token(&cfg, "Bearer dev:alice:Alice Smith").unwrap();
        assert_eq!(id.subject, "alice");
        assert_eq!(id.name.as_deref(), Some("Alice Smith"));
        assert_eq!(id.issuer, "concave:dev");
    }

    #[test]
    fn verifies_hs256_jwt() {
        let secret = "super-secret-key";
        let header = URL_SAFE_NO_PAD.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
        let payload = URL_SAFE_NO_PAD.encode(r#"{"sub":"u123","iss":"test-idp","name":"Bob"}"#);
        let signing_input = format!("{header}.{payload}");
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(signing_input.as_bytes());
        let sig = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        let jwt = format!("{signing_input}.{sig}");

        let cfg = AuthConfig {
            jwt_secret: Some(secret.into()),
            allow_dev_tokens: false,
        };
        let id = verify_token(&cfg, &jwt).unwrap();
        assert_eq!(id.subject, "u123");
        assert_eq!(id.issuer, "test-idp");
        assert_eq!(id.name.as_deref(), Some("Bob"));
    }
}
