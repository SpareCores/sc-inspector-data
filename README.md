# Spare Cores Inspector Data

Data collected by [`sparecores-inspector`](https://github.com/SpareCores/sc-inspector)
under the `data` folder using the `vendor/server` directory structure, referring to the
vendor by its `vendor_id`, and using the `api_reference` for the server.


# Collected data

## Viewing PassMark output

PassMark's [PerformanceTest](https://www.passmark.com/products/pt_linux/download.php) needs a terminal and prints its output with [ANSI escape codes](https://github.com/SpareCores/sc-inspector-data/blob/e49a5d4efe496e77ac8721e6b7910b138a2dff41/data/aws/r5.large/passmark/stderr#L1).

To view this output, you can use for example [ttyplay](https://manpages.ubuntu.com/manpages/noble/man1/ttyplay.1.html) if the file won't render correctly in your terminal
using a simple `cat`.
