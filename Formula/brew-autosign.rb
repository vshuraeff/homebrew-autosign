class BrewAutosign < Formula
  desc "Auto-sign unsigned brew binaries to keep Keychain ACLs valid across upgrades"
  homepage "https://github.com/vshuraeff/homebrew-autosign"
  url "https://github.com/vshuraeff/homebrew-autosign/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "e38cf635dcb7c60f8fff042353c49d9c48672e05788b8cb4cd732e6e3161d224"
  license "MIT"
  head "https://github.com/vshuraeff/homebrew-autosign.git", branch: "master"

  depends_on :macos
  depends_on "util-linux" # provides flock(1), absent from macOS by default

  def install
    bin.install "bin/brew-autosign"
    (pkgshare).install "share/packages.conf.example"
    doc.install "README.md", "docs", "LICENSE"

    # Generate completions via the CLI itself so they always match the
    # currently-installed binary. Brew places them under the formula's
    # appropriate share/<shell>/site-functions or vendor_completions.d.
    generate_completions_from_executable(
      bin/"brew-autosign",
      "completions",
      "generate",
      shells: [:bash, :zsh, :fish]
    )
  end

  def caveats
    <<~EOS
      After install (and on every upgrade), run setup if you have not already:
        brew-autosign setup

      This will:
        - generate a self-signed ECDSA P-521 code-signing certificate
          (SHA-512, 10 years) in a private temporary directory,
        - import it into your login keychain and trust it for the codeSign
          policy (you will be prompted for your login password),
        - delete the private key and PKCS12 from disk (only the public .crt
          is retained for fingerprint / expiry checks),
        - create #{Tty.bold}~/.config/brew-autosign/packages.conf#{Tty.reset},
        - install a LaunchAgent that re-signs configured Homebrew binaries
          after every `brew upgrade` and runs a backstop sign pass hourly.

      Then add packages whose Keychain ACLs you want kept stable:
        brew-autosign add fnox

      Health check anytime:
        brew-autosign status

      Docs are installed alongside the formula:
        brew info brew-autosign
      and live under #{opt_share}/doc/brew-autosign/

      To remove only the LaunchAgent (keeps cert and config):
        brew-autosign uninstall

      To fully remove (deletes cert + Keychain identity):
        brew-autosign uninstall --purge
    EOS
  end

  test do
    assert_match "Subcommands:", shell_output("#{bin}/brew-autosign help")
    # ensure validation rejects malformed inputs
    assert_match "invalid", shell_output("#{bin}/brew-autosign add '../etc/passwd' 2>&1", 1)
  end
end
