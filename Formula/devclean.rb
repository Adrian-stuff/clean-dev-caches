class Devclean < Formula
  desc "Free disk space: dev caches, stale builds, merged worktrees and unused tools"
  homepage "https://github.com/Adrian-stuff/clean-dev-caches"
  url "https://github.com/Adrian-stuff/clean-dev-caches/archive/refs/tags/v1.2.2.tar.gz"
  sha256 "7cecb84ad05f3e4dfc5b663d24f24fc786cee240e6f1d262292ca389a82ad433"
  license "MIT"
  head "https://github.com/Adrian-stuff/clean-dev-caches.git", branch: "main"

  def install
    bin.install "skills/clean-dev-caches/scripts/devclean.sh" => "devclean"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/devclean --version")
  end
end
