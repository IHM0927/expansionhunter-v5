version 1.0
## ExpansionHunter(Original) Pipeline in WDL

# WORKFLOW DEFINITION
workflow EHO {

    input {
        # Sample information
		File cram
		File crai
        String? name
        String sex
        
        # References
        File ref_fasta
        File ref_fasta_index
        File variant_catalog
    }

    call EHO {
        input:
            cram = cram,
            crai = crai,
            sex = sex,
            ref_fasta = ref_fasta,
            ref_fasta_index = ref_fasta_index,
            variant_catalog = variant_catalog
    }

	output {
		File json = EHO.json
        File bam = EHO.bam
        File vcf = EHO.vcf
	}
}

# TASK DEFINITIONS

task EHO {

    input {
        File cram
        File crai
        String name = basename(cram, ".cram")
        String sex
        File variant_catalog

        # References
        File ref_fasta
        File ref_fasta_index
		
		# Runtime parameters
		String docker = "hydragenetics/expansionhunter:5.0.0"
		Int? cpu = 1
		Float? machine_mem_gb = 1.8
    }

    command <<<
        set -e 
        ExpansionHunter --reads ~{cram} --reference ~{ref_fasta} --variant-catalog ~{variant_catalog} --output-prefix ~{name}.EH --sex ~{sex}
    >>>
	
	runtime {
		docker: docker
		memory: machine_mem_gb + " GB"
		cpu: cpu
		disks: "local-disk " + ceil(2*size(cram, "G")) + " HDD"
	}

    output {
        File json = "~{name}.EH.json"
        File bam = "~{name}.EH_realigned.bam"
        File vcf = "~{name}.EH.vcf"
    }
}
