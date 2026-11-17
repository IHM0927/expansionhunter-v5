version 1.0

# Gather eight disjoint ExpansionHunter catalogs from one sample and reference.
# Input order and basenames do not need to match genomic order or catalog names.
workflow MergeEhVcfs {
  input {
    Array[File] vcfs
    String output_prefix = "sample"
  }

  call GatherVcfs {
    input:
      vcfs = vcfs,
      output_prefix = output_prefix
  }

  output {
    File merged_vcf = GatherVcfs.merged_vcf
    File merged_vcf_index = GatherVcfs.merged_vcf_index
  }

  parameter_meta {
    vcfs: "Eight single-sample ExpansionHunter .vcf or .vcf.gz files, one per catalog shard."
    output_prefix: "Output basename, e.g. W002 produces W002.EH.vcf.gz."
  }
}

task GatherVcfs {
  input {
    Array[File] vcfs
    String output_prefix
  }

  Int disk_gb = 20 + ceil(8 * size(vcfs, "GiB"))

  command <<<
    set -euo pipefail
    export LC_ALL=C

    fail() { echo "MergeEhVcfs: $*" >&2; exit 1; }

    # Localized paths can have the same basename. Retain the full paths.
    mapfile -t inputs <<'VCF_PATHS'
~{sep="\n" vcfs}
VCF_PATHS
    [[ ~{length(vcfs)} -eq 8 ]] || fail "Expected exactly eight input VCFs."
    # Read the user-provided basename as data, never as shell code.
    IFS= read -r prefix < "~{write_lines([output_prefix])}"
    [[ "$prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Invalid output_prefix."

    mkdir -p work out
    expected_records=0
    for i in "${!inputs[@]}"; do
      vcf="${inputs[i]}"
      for ((j=0; j<i; j++)); do
        [[ ! "$vcf" -ef "${inputs[j]}" ]] || fail "Input VCF supplied twice: $vcf"
      done

      bcftools query -l "$vcf" > work/sample.current
      [[ $(wc -l < work/sample.current) -eq 1 ]] || fail "Expected one sample in $vcf."
      if [[ "$i" -eq 0 ]]; then
        cp work/sample.current work/sample.expected
      else
        cmp -s work/sample.expected work/sample.current || fail "VCF sample mismatch: $vcf"
      fi

      sorted="work/part.$i.vcf.gz"
      bcftools sort -m 512M -T "work/sort.$i.XXXXXX" -Oz -o "$sorted" "$vcf"
      bcftools index --csi "$sorted"
      n=$(bcftools index --nrecords "$sorted")
      expected_records=$((expected_records + n))
      echo "$sorted" >> work/sorted.list
    done

    merged="out/$prefix.EH.vcf.gz"
    # Shards may interleave. Retain distinct STR records at the same position.
    bcftools concat --allow-overlaps --file-list work/sorted.list -Oz -o "$merged"
    bcftools index --csi "$merged"
    actual_records=$(bcftools index --nrecords "$merged")
    [[ "$actual_records" -eq "$expected_records" ]] || fail "Record count changed: $expected_records -> $actual_records"
    echo "Merged $actual_records records from 8 VCFs." >&2
  >>>

  output {
    File merged_vcf = "out/" + output_prefix + ".EH.vcf.gz"
    File merged_vcf_index = "out/" + output_prefix + ".EH.vcf.gz.csi"
  }

  runtime {
    docker: "quay.io/biocontainers/bcftools:1.18--h8b25389_0"
    cpu: 1
    memory: "4 GiB"
    disks: "local-disk " + disk_gb + " SSD"
  }
}
