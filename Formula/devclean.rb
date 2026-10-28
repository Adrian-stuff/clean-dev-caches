class Devclean < Formula
  desc "Free disk space: dev caches, stale builds, merged worktrees and unused tools"
  homepage "https://github.com/Adrian-stuff/clean-dev-caches"
  url "https://github.com/Adrian-stuff/clean-dev-caches/archive/refs/tags/v1.2.1.tar.gz"
  sha256 "eaa511d0baffc69b413ebd574cf8e4eeb83580cea418907340fe702a55d95794"
  license "MIT"
  head "https://github.com/Adrian-stuff/clean-dev-caches.git", branch: "main"

  def install
    bin.install "skills/clean-dev-caches/scripts/devclean.sh" => "devclean"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/devclean --version")
  end
end
