/**
 * Valence (https://valence.app) Adapter that can communicate with a SlashDB API endpoint.
 */
global with sharing class SlashDBAdapter implements valence.SourceAdapterScopeSerializer, valence.ChainFetchAdapter, valence.SchemaAdapter, valence.NamedCredentialAdapter, valence.ConfigurableSourceAdapter {

	public static final String DATETIME_FORMAT = 'yyyy-MM-dd\'T\'HH:mm:ss';

	@TestVisible private String namedCredentialName;
	@TestVisible private String databaseName;
	@TestVisible private FetchScope nextScope;
	@TestVisible private SourceConfiguration sourceConfig = new SourceConfiguration();


	// ----------------------------------
	// ----- NamedCredentialAdapter -----
	// ----------------------------------

	public void setNamedCredential(String namedCredentialName) {
		this.namedCredentialName = namedCredentialName;
		this.databaseName = namedCredentialName.split('_')[1];
	}

	// -------------------------
	// ----- SchemaAdapter -----
	// -------------------------

	public List<valence.Table> getTables() {

		List<valence.Table> tables = new List<valence.Table>();
		for(String tableName : parseJSONResponse(callEndpoint(buildQuery().compose())).get(databaseName).asMap().keySet()) {
			if(!'__href'.equalsIgnoreCase(tableName)) {
				tables.add(valence.Table.create(tableName).build());
			}
		}
		return tables;
	}

	public List<valence.Field> getFields(String tableApiName) {

		String query = buildQuery()
			.withTable(tableApiName)
			.withExtension('.xsd')
			.compose();

		// reach into the response structure to get the field list
		List<valence.Field> fields = new List<valence.Field>();
		for(DOM.XmlNode fieldInfo : parseXSDResponse(callEndpoint(query))) {
			String type = fieldInfo.getAttribute('type', null);
			fields.add(valence.Field.create(fieldInfo.getAttribute('name', null))
				.withType(String.isBlank(type) ? 'object' : type.split(':')[1])
				.build());
		}
		return fields;
	}

	// --------------------------------
	// ----- SourceAdapterForPull -----
	// --------------------------------

	public valence.FetchStrategy planFetch(valence.LinkContext context) {
		return valence.FetchStrategy.immediate();
	}

	public List<valence.RecordInFlight> fetchRecords(valence.LinkContext context, Object scope) {

		Long offset = scope == null ? 0 : ((FetchScope)scope).offset;
		String query = buildQuery()
			.withTable(context.linkSourceName)
			.withOffset(offset)
			.withBatchLimit(context.batchSizeLimit)
			.withSortColumn('ID')
			.withDelta(sourceConfig.deltaField, context.lastSuccessfulSync)
			.compose();

		List<valence.RecordInFlight> records = new List<valence.RecordInFlight>();
		for(valence.JSONParse record : parseJSONResponse(callEndpoint(query)).asList()) {
			records.add(new valence.RecordInFlight((Map<String, Object>)record.getValue()));
		}
		// decide if we need to make more calls to the API; if we were given a full batch of records, expect another batch is available
		nextScope = records.size() == context.batchSizeLimit ? new FetchScope(offset + context.batchSizeLimit) : null;
		return records;
	}

	// ----------------------------------------
	// ----- SourceAdapterScopeSerializer -----
	// ----------------------------------------

	public String serializeScope(Object scope) {
		return JSON.serialize(scope);
	}

	public Object deserializeScope(String serializedScope) {
		return (FetchScope)JSON.deserialize(serializedScope, FetchScope.class);
	}

	// -----------------------------
	// ----- ChainFetchAdapter -----
	// -----------------------------

	public Object getNextScope() {
		return nextScope;
	}

	// -------------------------------------
	// ----- ConfigurableSourceAdapter -----
	// -------------------------------------

	public String getSourceConfigurationLightningComponent(valence.LinkContext context) {
		return 'c:slashDBAdapterSourceConfigurator';
	}

	public String getSourceConfigurationStructure(valence.LinkContext context) {
		return null;
	}

	public String explainSourceConfiguration(valence.LinkContext context, String configurationData) {

		SourceConfiguration sourceConfig = parseSourceConfig(configurationData);

		if(String.isBlank(sourceConfig.deltaField)) {
			return 'Fetches every record in the table each time it runs.';
		} else {
			return 'Fetches records modified since last run by inspecting <strong>' + sourceConfig.deltaField + '</strong>.';
		}
	}

	public void setSourceConfiguration(valence.LinkContext context, String configurationData) {

		sourceConfig = parseSourceConfig(configurationData);
	}

	// ---------------------------
	// ----- Utility methods -----
	// ---------------------------

	private SourceConfiguration parseSourceConfig(String configData) {
		if(String.isNotBlank(configData)) {
			return (SourceConfiguration)JSON.deserialize(configData, SourceConfiguration.class);
		}
		else {
			return new SourceConfiguration();
		}
	}

	/**
	 * Interpret a JSON response from the API to make it easier to work with.
	 *
	 * @param res An HTTPResponse received from the API whose body is expected to contain JSON-formatted data
	 *
	 * @return A friendlier representation of that response
	 */
	private valence.JSONParse parseJSONResponse(HttpResponse res) {
		return new valence.JSONParse(res.getBody());
	}

	/**
	 * Interpret an XSD response from the API to make it easier to work with.
	 *
	 * @param res An HTTPResponse received from the API whose body is expected to contain XSD-formatted data
	 *
	 * @return A friendlier representation of that response in an XML format
	 */
	private List<DOM.XmlNode> parseXSDResponse(HttpResponse res) {
		// set up the XML response for inspection
		return res.getBodyDocument().getRootElement() // schema
			.getChildElements()[0] // slashDB element
			.getChildElements()[0] // complexType
			.getChildElements()[0] // sequence
			.getChildElements()[0] // table element
			.getChildElements()[0] // complexType
			.getChildElements()[0] // sequence
			.getChildElements(); // things we actually care about
	}

	/**
	 * Send a request to the given endpoint and return the response. Also checks the response for errors before returning.
	 *
	 * @param endpoint The URL to call
	 *
	 * @return The response from the remote API
	 */
	private HttpResponse callEndpoint(String endpoint) {

		// build the request
		HttpRequest req = buildRequest(endpoint);

		// call the API
		HttpResponse res = new Http().send(req);

		// check the response status
		checkForHttpErrors(res, endpoint);

		return res;
	}

	/**
	 * Prepare an HTTPRequest instance with some default values
	 *
	 * @param endpoint The URL to call
	 *
	 * @return An HTTPRequest instance ready to send
	 */
	private HttpRequest buildRequest(String endpoint) {

		HttpRequest req = new HttpRequest();
		req.setMethod('GET');
		req.setTimeout(120000);
		req.setCompressed(true);
		req.setEndpoint(endpoint);
		req.setHeader('apikey', '{!$Credential.Password}');
		return req;
	}

	/**
	 * Check for errors at the transport layer of an HTTP response.
	 *
	 * @param response The response from the API
	 * @param endpoint The URL that was called
	 */
	private void checkForHttpErrors(HttpResponse response, String endpoint) {
		if(response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
			throw new valence.AdapterException(response.getStatusCode() + ':' + response.getStatus() + '\n ' + response.getBody() + '[' + endpoint + ']');
		}
	}

	/**
	 * @return A new Query instance ready to be refined or used
	 */
	private Query buildQuery() {
		return new Query(namedCredentialName, databaseName);
	}

	/**
	 * Contains the various properties that might be part of a query to the API to make composing queries a little simpler.
	 */
	private class Query {

		final String namedCredentialName;
		final String databaseName;
		Integer batchLimit = null;
		String tableName = null;
		Long offset = null;
		String extension = null;
		String sortColumn = null;
		String deltaField = null;
		Datetime deltaTimestamp = null;

		Query(String namedCredentialName, String databaseName) {
			this.namedCredentialName = namedCredentialName;
			this.databaseName = databaseName;
		}

		Query withBatchLimit(Integer value) {
			batchLimit = value;
			return this;
		}

		Query withTable(String value) {
			tableName = value;
			return this;
		}

		Query withOffset(Long value) {
			offset = value;
			return this;
		}

		Query withExtension(String value) {
			extension = value;
			return this;
		}

		Query withSortColumn(String value) {
			sortColumn = value;
			return this;
		}

		Query withDelta(String fieldName, Datetime timestamp) {
			deltaField = fieldName;
			deltaTimestamp = timestamp;
			return this;
		}

		String compose() {

			/*
			 * Build any column filtering that will be needed
			 */
			List<String> filters = new List<String>();
			if(deltaField != null & deltaTimestamp != null) {
				filters.add('/' + encode(deltaField) + '/' + deltaTimestamp.formatGmt(DATETIME_FORMAT) + '..');
			}
			String filterString = filters.isEmpty() ? '' : String.join(filters, '');

			/*
			 * Calculate what the URL parameters will be
			 */
			List<String> params = new List<String>{
				'href=false'
			};
			if(batchLimit != null) {
				params.add('limit=' + batchLimit);
			}
			if(offset != null) {
				params.add('offset=' + offset);
			}
			if(sortColumn != null) {
				params.add('sort=' + encode(sortColumn));
			}
			String paramString = params.isEmpty() ? '' : '?' + String.join(params, '&');

			return String.format('callout:{0}/{1}{2}{3}{4}{5}', new List<String>{
				namedCredentialName,
				databaseName,
				tableName == null ? '' : '/' + tableName,
				filterString,
				extension == null ? '.json' : extension,
				paramString
			});
		}

		String encode(String value) {
			return EncodingUtil.urlEncode(value, 'UTF-8');
		}
	}

	private class SourceConfiguration {

		private String deltaField;
	}

	/**
	 * Simple wrapper class that holds information we would need for a single batch call to the API.
	 */
	@TestVisible
	private class FetchScope {

		private Long offset;

		@TestVisible
		private FetchScope(Long offset) {
			this.offset = offset;
		}
	}
}