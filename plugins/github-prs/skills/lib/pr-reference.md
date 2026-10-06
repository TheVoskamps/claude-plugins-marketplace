# PR references

Every verb here that takes a PR takes it as one argument in any of
these forms, resolved against the current repository — the one the
checkout's remote names, on that remote's host:

| Form | PR |
| --- | --- |
| `N`, `#N` | PR N in the current repository |
| `repo#N` | in `repo` under the current repository's owner, on its host |
| `owner/repo#N` | in that repository, on the current repository's host |
| `host/owner/repo#N` | in that repository, on that host |
| `https://host/owner/repo/pull/N` | the same as `host/owner/repo#N`; a trailing `/` is ignored |

An issue URL, `https://host/owner/repo/issues/N`, and anything else is
a usage error, exit 2, naming the accepted forms; the script calls
nothing. A form that names a repository sends every `gh` call to that
repository on that host.

The **canonical reference** of a PR is `host/owner/repo#N`, taken from
its base repository — a fork PR's head repository is the fork, and the
PR lives on its base. `/pr-view <PR> --ref` prints it. Pass a PR
onward in that form: it names the same PR from any checkout.

A message that names the PR spells it `#N` when the argument named no
repository, and by its canonical reference otherwise.
