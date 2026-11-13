//! The host program: keeps a session running with no terminal attached. See
//! `cooked::host`, where all of it is.

fn main() -> std::process::ExitCode {
    cooked::host::main()
}
