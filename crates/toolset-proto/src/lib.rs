pub mod toolset {
    pub mod v1 {
        tonic::include_proto!("toolset.v1");
    }
}

pub use proto_common::*;
pub use toolset::v1::*;

pub const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("toolset_descriptor");
