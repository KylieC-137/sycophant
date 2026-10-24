use crate::runner::run_silent;

fn pass(label: &str) {
    println!("\x1b[32m✓\x1b[0m {label}");
}

fn fail(label: &str, fix: &str) {
    println!("\x1b[31m✗\x1b[0m {label}");
    println!("  fix: {fix}");
}

fn warn(message: &str) {
    println!("\x1b[33m⚠\x1b[0m {message}");
}

fn require(failures: &mut usize, label: &str, successful: bool, fix: &str) {
    if successful {
        pass(label);
    } else {
        fail(label, fix);
        *failures += 1;
    }
}

pub(crate) fn run() -> Result<(), String> {
    let mut failures = 0usize;

    println!("Sycophant Environment Diagnostics");
    println!("Read-only: no dependencies will be installed or modified.");
    println!();
    println!("-- Toolchain --");

    // Check Docker
    require(
        &mut failures,
        "Docker (running)",
        run_silent("docker", &["info"]),
        "Install/start Docker: https://docs.docker.com/engine/install/",
    );

    // Check k3d
    require(
        &mut failures,
        "k3d",
        run_silent("k3d", &["version"]),
        "Install k3d: https://k3d.io/",
    );

    // Check Helm
    require(
        &mut failures,
        "Helm",
        run_silent("helm", &["version"]),
        "Install Helm: https://helm.sh/docs/intro/install/",
    );

    // Check kubectl
    require(
        &mut failures,
        "kubectl",
        run_silent("kubectl", &["version", "--client"]),
        "Install kubectl: https://kubernetes.io/docs/tasks/tools/",
    );

    // Check Cargo
    require(
        &mut failures,
        "Cargo",
        run_silent("cargo", &["--version"]),
        "Install Rust and Cargo: https://rustup.rs/",
    );

    // Check protoc
    require(
        &mut failures,
        "protoc",
        run_silent("protoc", &["--version"]),
        "Install protobuf-compiler (Ubuntu: sudo apt-get install -y protobuf-compiler)",
    );

    // Check CMake
    require(
        &mut failures,
        "CMake",
        run_silent("cmake", &["--version"]),
        "Install CMake (Ubuntu: sudo apt-get install -y cmake)",
    );

    // Check jq
    require(
        &mut failures,
        "jq",
        run_silent("jq", &["--version"]),
        "Install jq (Ubuntu: sudo apt-get install -y jq)",
    );

    // Check OpenSSL
    require(
        &mut failures,
        "OpenSSL",
        run_silent("openssl", &["version"]),
        "Install OpenSSL (Ubuntu: sudo apt-get install -y openssl)",
    );

    // Check Python's PyJWT module
    require(
        &mut failures,
        "PyJWT",
        run_silent("python3", &["-c", "import jwt"]),
        "Install PyJWT: python3 -m pip install pyjwt",
    );

    // Check grpcurl
    require(
        &mut failures,
        "grpcurl",
        run_silent("grpcurl", &["--version"]),
        "Install grpcurl: https://github.com/fullstorydev/grpcurl/releases",
    );

    // Check Tailscale
    require(
        &mut failures,
        "Tailscale",
        run_silent("tailscale", &["version"]),
        "Install Tailscale: https://tailscale.com/download",
    );

    // Check native C compiler on Linux
    if cfg!(target_os = "linux") {
        require(
            &mut failures,
            "C compiler (cc)",
            run_silent("cc", &["--version"]),
            "Install build tools: sudo apt-get install -y build-essential",
        );
    } else if cfg!(target_os = "macos") {
        require(
            &mut failures,
            "Xcode command-line tools",
            run_silent("xcode-select", &["-p"]),
            "Run: xcode-select --install",
        );
    }

    println!();

    if failures == 0 {
        println!("Doctor OK: all checked prerequisites are present.");
        Ok(())
    } else {
        Err(format!("{failures} required prerequisite(s) missing"))
    }
}
