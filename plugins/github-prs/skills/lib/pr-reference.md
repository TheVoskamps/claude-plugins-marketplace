# PR references

Every verb here that takes a PR takes it as one argument in any form
`github-ref item --type pr` parses — `github-ref` is the github-tools
plugin's, and holds the forms and the rules each part of a reference
is checked against. A form that leaves out its repository, owner or
host takes it from the current repository, the one the checkout's
`origin` remote names. An issue URL, and any other reference
`github-ref` refuses, is a usage error, exit 2, naming the accepted
forms; the script calls nothing. A form that names a repository sends
every `gh` call to that repository on that host.

The **canonical reference** of a PR is `host/owner/repo#N`, taken from
its base repository — a fork PR's head repository is the fork, and the
PR lives on its base. `/pr-view <PR> --ref` prints it. Pass a PR
onward in that form: it names the same PR from any checkout.

A message that names the PR spells it `#N` when the argument named no
repository, and by its canonical reference otherwise.
