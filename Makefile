# What is a makefile: https://medium.com/aigent/makefiles-for-python-and-beyond-5cf28349bf05
# example usage: make bootstrap
VENV := .venv
PYTHON_VERSION := 3.11.9
PROFILES_DIR := $(if $(DBT_PROFILES_DIR),$(DBT_PROFILES_DIR),$(HOME)/.dbt)
INTEGRATION_TESTS := integration_tests
DBT := $(CURDIR)/$(VENV)/bin/dbt

help:
	$(info make commands:)
	$(info - bootstrap - installs all prerequisites and configures your developer environment. Run this if this is your first time working in this repo.)
	$(info - update - refreshes the integration_tests dbt project's package dependencies)
	$(info - profile - (re)checks/appends the dbt_tripwire_poc profile without touching the rest of profiles.yml)
	$(info - destroy - [DANGER] uninstalls all dependencies and project configs (does not affect your dbt profile))

###################################################################################################
# Main Operations
###################################################################################################

bootstrap: _python_environment _external_dependencies _profile _dbt_dependencies _pre_commit_install _exit_message

update: _dbt_clean _dbt_dependencies _exit_message

profile: _profile

destroy: _dbt_clean _pre_commit_uninstall
	-rm -r $(VENV)
	-pyenv local --unset
	-pyenv uninstall $(PYTHON_VERSION)
	@echo "The development environment has been destroyed. Thank you"

###################################################################################################
# Sub Operations: Not intended to be called from CLI
###################################################################################################

$(VENV)/bin/activate: requirements.txt
	~/.pyenv/shims/python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -r requirements.txt

_venv: $(VENV)/bin/activate

_python_environment:
	@if ! grep -Fxq 'eval "$$(pyenv init -)"' ~/.zshrc 2>/dev/null; then \
		echo "eval \"\$$(pyenv init -)\"" >> ~/.zshrc; \
	fi
	@if ! grep -Fxq "alias activate!='source $(VENV)/bin/activate'" ~/.zshrc 2>/dev/null; then \
		echo "alias activate!='source $(VENV)/bin/activate'" >> ~/.zshrc; \
	fi
	@if ! grep -Fxq 'eval "$$(pyenv init -)"' ~/.bash_profile 2>/dev/null; then \
		echo 'eval "$$(pyenv init -)"' >> ~/.bash_profile; \
	fi
	@if ! grep -Fxq "alias activate!='source $(VENV)/bin/activate'" ~/.bash_profile 2>/dev/null; then \
		echo "alias activate!='source $(VENV)/bin/activate'" >> ~/.bash_profile; \
	fi

_external_dependencies:
	brew bundle install
	# ignoring errors (dash) because an already-installed version exits non-zero
	-pyenv install $(PYTHON_VERSION)
	pyenv local $(PYTHON_VERSION)

# Unlike some project Makefiles, this never overwrites profiles.yml -- that file
# is commonly shared with other dbt projects on the same machine (e.g.
# another project's own Snowflake profile). It only appends a
# dbt_tripwire_poc block, and only if one isn't already present.
_profile:
	@echo "\nChecking profile path: $(PROFILES_DIR)/profiles.yml"
	@mkdir -p $(PROFILES_DIR)
	@touch "$(PROFILES_DIR)/profiles.yml"
	@if grep -Fxq "dbt_tripwire_poc:" "$(PROFILES_DIR)/profiles.yml"; then \
		echo "dbt_tripwire_poc profile already present in $(PROFILES_DIR)/profiles.yml -- leaving it as-is."; \
	else \
		echo "No dbt_tripwire_poc profile found -- appending one to $(PROFILES_DIR)/profiles.yml"; \
		read -p "What email address should be used for this dbt profile? " user_email; \
		read -p "What is the account identifier? (hint: [account-locator].us-east-2.aws): " account_identifier; \
		read -p "What is your default role? (hint: workspace_owner_[first-initial][last-name]): " ws_role; \
		read -p "What is your workspace schema name? (hint: ws_[first-initial][last-name]_sao_poc): " ws_schema; \
		echo "" >> "$(PROFILES_DIR)/profiles.yml"; \
		sed \
			-e "s/{{USER_EMAIL}}/$$user_email/g" \
			-e "s/{{ACCOUNT_IDENTIFIER}}/$$account_identifier/g" \
			-e "s/{{WS_ROLE}}/$$ws_role/g" \
			-e "s/{{WS_SCHEMA}}/$$ws_schema/g" \
			.profiles.template.yml >> "$(PROFILES_DIR)/profiles.yml"; \
		echo "dbt_tripwire_poc profile appended. Run 'cd $(INTEGRATION_TESTS) && dbt debug' to verify."; \
	fi

_dbt_clean: _venv
	cd $(INTEGRATION_TESTS) && $(DBT) clean

_dbt_dependencies: _venv
	cd $(INTEGRATION_TESTS) && $(DBT) deps

_pre_commit_install: _venv
	$(VENV)/bin/pre-commit install

_pre_commit_uninstall:
	-$(VENV)/bin/pre-commit uninstall -t pre-commit -t pre-push

_exit_message:
	$(info ----------)
	$(info Setup Complete!)
	$(info TIP: To activate the virtual environment use 'activate!')
	$(info TIP: dbt commands for this package are run from integration_tests/, e.g. 'cd integration_tests && dbt debug')
	$(info ----------)
	$(info Please run 'source ~/.zshrc' or restart the terminal to apply changes)
