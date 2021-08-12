/**
 * Allows Users to configure the SlashDB Adapter for Valence.
 */

import ValenceUIConfigurator from 'c/valenceUIConfigurator';

export default class SlashDBAdapterSourceConfigurator extends ValenceUIConfigurator {

	deltaCandidates = [];

	// ------------------------------------------
	// ----- Configurator Lifecycle Methods -----
	// ------------------------------------------

	/**
	 * Set up our deltaCandidates whenever we are given schema
	 */
	onSetSchema() {
		console.log('setSchema: ', JSON.parse(JSON.stringify(this.schema)));

		if(!this.schema) {
			return;
		}

		// set up selection options for the field that will be tested against for last modified date
		this.deltaCandidates = [{'value' : '--noSelection--', 'label' : '-- None --'}];
		Object.values(this.schema.Source.children).forEach((node) => {
			this.deltaCandidates.push({'value' : node.field.fieldName, 'label' : this._prettyFieldLabel(node.field.fieldName, node.field.fieldLabel)});
			// note: we deliberately ignored any nested schema fields as they are unlikely to usable for what we're doing here
		});
		this.deltaCandidates.sort((a, b) => a.value === '--noSelection--' ? -1 : a.value.localeCompare(b.value));
	}

	_prettyFieldLabel(name, label) {
		return name + (name !== label && label ? ' (' + label + ')' : '');
	}

	// -------------------------------------------
	// ----- User Manipulating Configuration -----
	// -------------------------------------------

	fieldSelected(event) {
		this.configuration.deltaField = event.target.value === '--noSelection--' ? null : event.target.value;
		this.configUpdated(); // propagate our configuration changes
	}

	// -----------------------------------------
	// ----- Required Configurator Methods -----
	// -----------------------------------------

	getDefaultShape() {
		return {deltaField : null};
	}

	computeValid() {
		return true; // always valid
	}
}