// package metrics implements a metrics client which will calculate llms specific metrics.
package metrics

import (
	"encoding/json"
	"log"
	"time"

	"github.com/soypete/pedro-ops/internal/middleware"
	"github.com/soypete/pedro-ops/types"
)

type Calculater interface {
	// CalculateMetrics calculates the metrics from the given response. the []bytes is passed right to
	// the json unmarshaler. so you will need to allocate the slice from your io reader body.
	CalculateMetrics([]byte) types.ResponseMetrics
}

type OpenAICalculator struct {
	// promethues client
	mw *middleware.OpenAIMiddleware
}

func SetupCalulator() *OpenAICalculator {
	return &OpenAICalculator{
		mw: middleware.NewOpenAIMiddleware(),
	}

}

// CalculateMetrics calculates the metrics from the given response. the []bytes is passed right to
// the json unmarshaler. so you will need to allocate the slice from your io reader body. opts include in
// order, time that the request was made, and endpoint name.
func (c *OpenAICalculator) CalculateMetrics(respBody []byte, opts ...any) (types.ResponseMetrics, map[string]float64, error) {
	var responseMetrics types.ResponseMetrics // TODO: maybe have this be an optional config that is passed
	var endpointName string

	// check if opts were sent
	if len(opts) < 1 {
		responseMetrics.RequestStartTime = time.Now()
		responseMetrics.ResponseStartTime = time.Now()
		endpointName = "completions" // default to completions
	} else {
		responseMetrics.RequestStartTime = opts[0].(time.Time)
		responseMetrics.ResponseStartTime = time.Now()
		endpointName = opts[1].(string)
	}

	err := json.Unmarshal(respBody, &responseMetrics)
	if err != nil {
		log.Printf("Error unmarshalling response body: %v", err)
		return responseMetrics, nil, err
	}

	// extractMetrics extracts metrics from the response body and updates the responseMetrics struct
	responseMetrics.ResponseSize = int64(len(respBody))
	responseMetrics.ResponseEndTime = time.Now()
	responseMetrics.FirstTokenTime = responseMetrics.ResponseEndTime

	// Extract metrics from response
	c.mw.ExtractMetrics(respBody, &responseMetrics, endpointName)
	metrics := responseMetrics.CalculateMetrics() // get derived metrics

	return responseMetrics, metrics, nil
}
