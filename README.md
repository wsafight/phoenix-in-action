# Phoenix in Action

<img src="support/phoenix-in-action-cover.png" alt="Phoenix in Action cover" height="200px" />

Thanks for checking out the code listings and snippets from Phoenix in
Action!

As the book goes through the MEAP process, I will be attempting to
keep this repo up to date with what is available in MEAP. The
organization will be by chapter. Inside each chapter directory, you'll
be able to see how the project code should look by the end of that
specific chapter.

Please let me know if you spot any errors or if any listing does not
work for you.

## Modernized code & companion book site

All chapter code has been migrated from Phoenix 1.4 to **Phoenix 1.7/1.8
style** (heex templates, function components, CoreComponents, verified
routes, Bandit). See [MIGRATION.md](MIGRATION.md) for the full change list.

A companion tutorial book (in Chinese), built with
[Astro Starlight](https://starlight.astro.build/), lives in [`site/`](site/).
It is built and deployed to GitHub Pages by
[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml).

```bash
cd site && npm install && npm run dev   # local preview
```

## Buy the book!

If you don't already have the book, you can [buy it from Manning][pia].

[pia]: https://www.manning.com/books/phoenix-in-action?a_aid=geolessel&a_bid=80a2cec0
