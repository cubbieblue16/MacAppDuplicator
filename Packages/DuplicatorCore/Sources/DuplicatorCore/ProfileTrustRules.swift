import Foundation

/// The rules a remote compatibility profile must pass before its arguments, environment or New Window command are
/// copied into a shortcut. They live in DuplicatorCore so the profile validator (CompatProfiles) and the wizard (App)
/// enforce one definition.
public enum ProfileTrustRules {
    /// Environment keys a profile may not set (anchored, keys are case-sensitive except the `_proxy` suffix):
    /// - code loaders: dynamic-loader (`DYLD_`, `LD_`), Node (`NODE_` prefix, `ELECTRON_RUN_AS_NODE`) and JVM hooks;
    /// - interpreter and tool hooks that run a command in the target's child processes: `GIT_` (for example
    ///   `GIT_CONFIG_*` setting `core.fsmonitor`, `GIT_SSH_COMMAND`), `BASH_ENV`, `ENV`, `ZDOTDIR`, `PERL5*`,
    ///   `PYTHON*`, `RUBY*`, `LESS*`, `SHELL`, `PATH`, `TMPDIR`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`;
    /// - traffic interception: any `*_PROXY` variable (any case), `SSLKEYLOGFILE`, `NODE_TLS_REJECT_UNAUTHORIZED`,
    ///   `NODE_EXTRA_CA_CERTS`;
    /// - the launcher's own `MAD_` variables and the ones data separation owns (`HOME`, `CFFIXED_USER_HOME`,
    ///   Firefox's `XRE_` overrides).
    public static let refusedEnvironmentKeyPattern =
        #"\A(?:DYLD_|LD_|MAD_|XRE_|GIT_|PERL5|PYTHON|RUBY|LESS|NODE_)|\A(?:NODE_OPTIONS|ELECTRON_RUN_AS_NODE|JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|HOME|CFFIXED_USER_HOME|BASH_ENV|ENV|ZDOTDIR|SSLKEYLOGFILE|NODE_TLS_REJECT_UNAUTHORIZED|NODE_EXTRA_CA_CERTS|PATH|SHELL|TMPDIR|XDG_CONFIG_HOME|XDG_DATA_HOME)\z|(?i:_proxy)\z"#

    /// Argument prefixes a profile may not use, with one or two leading dashes in any case (Chromium accepts both):
    /// - debugger and remote-control switches, code loaders (`--load-extension`, `--renderer-cmd-prefix`, `-vmargs`,
    ///   `-javaagent`, `--js-flags`), sandbox and web-security switches (`--allow-file-access-from-files`,
    ///   `--allow-running-insecure-content`, `--unsafely-treat-insecure-origin-as-secure`, `--disable-features`,
    ///   `--enable-features`);
    /// - traffic-interception switches (`--proxy-server`, `--proxy-pac-url`, `--proxy-bypass-list`,
    ///   `--host-resolver-rules`, `--host-rules`, `--ignore-certificate-errors`, `--ssl-key-log-file`);
    /// - the profile and data-folder switches the planner owns (`--user-data-dir`, `--profile-directory`, Firefox
    ///   `-profile` and `-P`, Eclipse `-data` and `-configuration`).
    ///
    /// Arguments with a NUL or other control character are refused separately (`containsControlCharacter`).
    public static let refusedArgumentPattern =
        #"(?i)\A--?(?:inspect|remote-debugging|remote-allow-origins|load-extension|disable-extensions-except|disable-web-security|no-sandbox|renderer-cmd-prefix|utility-cmd-prefix|gpu-launcher|browser-subprocess-path|user-data-dir|profile|configuration|data\z|p\z|vm|javaagent|proxy-server|proxy-pac-url|proxy-bypass-list|host-resolver-rules|host-rules|ignore-certificate-errors|ssl-key-log-file|allow-running-insecure-content|unsafely-treat-insecure-origin-as-secure|disable-features|enable-features|js-flags|allow-file-access-from-files)"#

    /// `true` when `value` has a NUL, another C0 control character (below 0x20) or DEL.
    public static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// `true` when `value` matches the ICU regular expression `pattern` anywhere.
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
