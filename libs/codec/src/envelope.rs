//! Request/response envelopes. The wire shape is `{"method","params"}` for
//! requests and exactly one of `{"result":...}` / `{"error":{"code","message"}}`
//! for responses — mirrors Swift `RequestEnvelope` / `ResponseEnvelope`.

use serde::ser::SerializeMap;
use serde::{Deserialize, Serialize};

use crate::{Method, RpcError, Value};

/// `{"method":"...","params":{...}}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestEnvelope {
    pub method: Method,
    pub params: Value,
}

impl RequestEnvelope {
    pub fn new(method: Method, params: Value) -> Self {
        Self { method, params }
    }
}

/// `{"result":...}` or `{"error":{...}}` — exactly one key present.
#[derive(Debug, Clone, PartialEq)]
pub enum ResponseEnvelope {
    Result(Value),
    Error(RpcError),
}

impl Serialize for ResponseEnvelope {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut map = serializer.serialize_map(Some(1))?;
        match self {
            ResponseEnvelope::Result(v) => map.serialize_entry("result", v)?,
            ResponseEnvelope::Error(e) => map.serialize_entry("error", e)?,
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for ResponseEnvelope {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let map = serde_json::Map::deserialize(deserializer)?;
        if let Some(err) = map.get("error") {
            let error =
                serde_json::from_value::<RpcError>(err.clone()).map_err(serde::de::Error::custom)?;
            return Ok(ResponseEnvelope::Error(error));
        }
        if let Some(result) = map.get("result") {
            return Ok(ResponseEnvelope::Result(result.clone()));
        }
        Err(serde::de::Error::custom(
            "response has neither result nor error",
        ))
    }
}
